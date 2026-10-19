import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

// #16: the registries keep a per-directory index so that an update's `forget` touches only the directories it re-reads.
// The unit tests run random operations against a model that walks the whole table, as the registries did before the
// index; the fixture tests check updates that move records between directories against a full scan and `du`.

/// Deterministic random numbers (SplitMix64), so that a failure can be replayed.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `HardlinkRegistry` without sizes, every operation over the whole table.
private struct LinkModel: Equatable {
    struct Entry: Equatable {
        var owner: Int32
        var others: [Int32] = []
    }
    var table: [UInt64: Entry] = [:]

    mutating func claim(_ inode: UInt64, by dir: Int32) -> Bool {
        guard var e = table[inode] else {
            table[inode] = Entry(owner: dir)
            return true
        }
        defer { table[inode] = e }
        if e.owner == dir { return false }
        if e.owner < 0 {
            e.owner = dir
            e.others.removeAll { $0 == dir }
            return true
        }
        if !e.others.contains(dir) { e.others.append(dir) }
        return false
    }

    mutating func forget(_ dirs: Set<Int32>) {
        for (k, var e) in table {
            if dirs.contains(e.owner) { e.owner = -1 }
            e.others.removeAll { dirs.contains($0) }
            table[k] = e.owner < 0 && e.others.isEmpty ? nil : e
        }
    }

    mutating func resolveOrphans() -> [Int32] {
        var moved: [Int32] = []
        for k in table.keys.sorted() where table[k]!.owner < 0 {
            var e = table[k]!
            let next = e.others.removeFirst()
            e.owner = next
            table[k] = e
            moved.append(next)
        }
        return moved
    }

    mutating func remap(_ map: [Int32]) {
        for (k, var e) in table {
            if e.owner < 0 || map[Int(e.owner)] < 0 {
                table[k] = nil
                continue
            }
            e.owner = map[Int(e.owner)]
            e.others = e.others.compactMap { map[Int($0)] >= 0 ? map[Int($0)] : nil }
            table[k] = e
        }
    }
}

/// `CloneRegistry` without sizes, every operation over the whole table.
private struct CloneModel: Equatable {
    struct Entry: Equatable {
        var owner: Int32
        var original: Int32
        var others: [Int32] = []
    }
    var table: [UInt64: Entry] = [:]

    mutating func claim(_ cid: UInt64, original isOriginal: Bool, by dir: Int32) -> Bool {
        guard var e = table[cid] else {
            table[cid] = Entry(owner: dir, original: isOriginal ? dir : -1)
            return true
        }
        defer { table[cid] = e }
        if isOriginal { e.original = dir }
        if e.owner == dir { return false }
        if e.owner < 0 {
            e.owner = dir
            e.others.removeAll { $0 == dir }
            return true
        }
        if e.others.last != dir && (e.others.count > 64 || !e.others.contains(dir)) { e.others.append(dir) }
        return false
    }

    mutating func adopt(_ cid: UInt64, by dir: Int32) {
        guard var e = table[cid] else { return }
        defer { table[cid] = e }
        let previous = e.owner
        e.original = dir
        guard previous != dir else { return }
        e.owner = dir
        e.others.removeAll { $0 == dir }
        if previous >= 0 { e.others.append(previous) }
    }

    mutating func forget(_ dirs: Set<Int32>) {
        for (k, var e) in table {
            if dirs.contains(e.owner) { e.owner = -1 }
            if dirs.contains(e.original) { e.original = -1 }
            e.others.removeAll { dirs.contains($0) }
            table[k] = e.owner < 0 && e.others.isEmpty ? nil : e
        }
    }

    mutating func resolveOrphans() -> [Int32] {
        var moved: [Int32] = []
        for k in table.keys.sorted() where table[k]!.owner < 0 {
            var e = table[k]!
            let next = e.original >= 0 && e.others.contains(e.original) ? e.original : e.others.first!
            e.others.removeAll { $0 == next }
            e.owner = next
            table[k] = e
            moved.append(next)
        }
        return moved
    }

    mutating func preferOriginals() -> [Int32] {
        var moved: [Int32] = []
        for k in table.keys.sorted() {
            var e = table[k]!
            guard e.original >= 0 && e.owner >= 0 && e.owner != e.original else { continue }
            moved.append(e.owner)
            e.others.removeAll { $0 == e.original }
            e.others.append(e.owner)
            e.owner = e.original
            table[k] = e
        }
        return moved
    }
}

private func snapshot(_ r: HardlinkRegistry) -> LinkModel {
    LinkModel(table: r.table.mapValues { LinkModel.Entry(owner: $0.owner, others: $0.others) })
}

private func snapshot(_ r: CloneRegistry) -> CloneModel {
    CloneModel(table: r.table.mapValues { CloneModel.Entry(owner: $0.owner, original: $0.original, others: $0.others) })
}

/// A few distinct directories out of `0..<dirs`.
private func someDirs(_ g: inout SplitMix, _ dirs: Int32) -> Set<Int32> {
    Set((0..<Int.random(in: 1...3, using: &g)).map { _ in Int32.random(in: 0..<dirs, using: &g) })
}

@Suite("Registry index")
struct RegistryIndexTests {
    @Test(
        "hard links: forget, orphans and remap through the index equal a walk of the whole table",
        arguments: [
            false, true,
        ])
    func hardlinksMatchModel(indexFirst: Bool) {
        var g = SplitMix(state: indexFirst ? 16 : 17)
        let r = HardlinkRegistry()
        var model = LinkModel()
        if indexFirst { r.buildIndex() }
        var dirs: Int32 = 16
        for step in 0..<4000 {
            switch Int.random(in: 0..<10, using: &g) {
            case 0..<6:
                let inode = UInt64.random(in: 0..<60, using: &g), dir = Int32.random(in: 0..<dirs, using: &g)
                let counted = r.claim(inode, by: dir, alloc: 4096, logical: 10, cloneAware: 4096)
                #expect(counted == model.claim(inode, by: dir), "step \(step)")
            case 6..<8:
                // As in an update, the re-reads claim again before the orphans are settled.
                let forgotten = someDirs(&g, dirs)
                r.forget(forgotten)
                model.forget(forgotten)
            case 8:
                #expect(r.resolveOrphans().map(\.dir) == model.resolveOrphans(), "step \(step)")
            default:
                // Drop one directory and renumber the others, as `compact` does.
                let dropped = Int32.random(in: 0..<dirs, using: &g)
                let map = (0..<dirs).map { $0 == dropped ? -1 : ($0 < dropped ? $0 : $0 - 1) }
                r.forget([dropped])
                model.forget([dropped])
                #expect(r.resolveOrphans().map(\.dir) == model.resolveOrphans(), "step \(step)")
                r.remap(map)
                model.remap(map)
                dirs -= 1
                if dirs < 8 { dirs = 16 }
            }
            #expect(snapshot(r) == model, "step \(step)")
            if snapshot(r) != model { return }
        }
    }

    @Test(
        "clones: forget, orphans, adopt and preferred originals through the index equal a walk of the table",
        arguments: [
            false, true,
        ])
    func clonesMatchModel(indexFirst: Bool) {
        var g = SplitMix(state: indexFirst ? 61 : 62)
        let r = CloneRegistry()
        var model = CloneModel()
        if indexFirst { r.buildIndex() }
        for round in 0..<200 {
            // Each round is one update: only the families it touches are checked for their original's directory.
            r.beginUpdate()
            for step in 0..<20 {
                let at = "round \(round) step \(step)"
                switch Int.random(in: 0..<10, using: &g) {
                case 0..<6:
                    let cid = UInt64.random(in: 0..<40, using: &g), dir = Int32.random(in: 0..<14, using: &g)
                    let original = Int.random(in: 0..<5, using: &g) == 0
                    let bytes = r.claim([CloneMember(cloneID: cid, alloc: 100, isOriginal: original)], by: dir).bytes
                    #expect((bytes == 100) == model.claim(cid, original: original, by: dir), "\(at)")
                case 6:
                    let cid = UInt64.random(in: 0..<40, using: &g), dir = Int32.random(in: 0..<14, using: &g)
                    _ = r.adopt(cid, by: dir)
                    model.adopt(cid, by: dir)
                default:
                    let forgotten = someDirs(&g, 14)
                    r.forget(forgotten)
                    model.forget(forgotten)
                    #expect(r.resolveOrphans().map(\.dir) == model.resolveOrphans(), "\(at)")
                }
                #expect(snapshot(r) == model, "\(at)")
            }
            #expect(r.preferOriginals().map(\.from) == model.preferOriginals(), "round \(round)")
            r.endUpdate()
            #expect(snapshot(r) == model, "round \(round)")
            if snapshot(r) != model { return }
        }
    }

    @Test("a stale key left by a removed entry does not touch the entry that reuses its id")
    func staleKeys() {
        let r = HardlinkRegistry()
        r.buildIndex()
        #expect(r.claim(5, by: 1, alloc: 1, logical: 1, cloneAware: 1))
        #expect(!r.claim(5, by: 2, alloc: 1, logical: 1, cloneAware: 1))
        r.forget([1, 2])
        #expect(r.table.isEmpty)
        // Directory 3 claims the same inode afresh; directory 1 is re-read again and must not release it.
        #expect(r.claim(5, by: 3, alloc: 1, logical: 1, cloneAware: 1))
        r.forget([1])
        #expect(r.table[5]?.owner == 3)
        #expect(r.resolveOrphans().isEmpty)
    }
}

/// Every update of `tree` with `events`, compared with a full scan of the same root and with `du`. Run once on a tree
/// loaded from a snapshot (index built by `load`) and once on a tree scanned in this process (index built by the
/// first `forget`).
private func updateMatchesFullScan(
    _ f: Fixture, snapshotDir: URL, events: [String], mustScanSubDirs: Bool = false,
    change: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let scanned = try Scanner.scan(f.root)
    try Snapshot.save(try Scanner.scan(f.root), in: snapshotDir)
    try change()
    let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: snapshotDir).tree)
    for (label, tree) in [("loaded", loaded), ("scanned", scanned)] {
        var report = UpdateReport()
        let failure = Incremental.applyTracked(
            events.map { EventHistory.Event(path: f.path($0), mustScanSubDirs: mustScanSubDirs) }, to: tree,
            options: ScanOptions(), report: &report)
        #expect(failure == nil, "\(label)", sourceLocation: sourceLocation)
        let full = try Scanner.scan(f.root)
        #expect(
            Totals(tree).sameRoot(as: Totals(full)), "\(label): \(Totals(tree)) full \(Totals(full))",
            sourceLocation: sourceLocation)
        #expect(tree.root.totalAlloc == f.duBytes(), "\(label)", sourceLocation: sourceLocation)
        // Records left behind by a missed `forget` would count twice or keep a dead owner: a second update that
        // re-reads every folder must still agree with the full scan. (Shallow re-reads: a rescan of the root would meet
        // the old hard links after their records were dropped, which strict mode refuses.)
        var again = UpdateReport()
        let all = tree.nodes.indices.filter { !tree.nodes[$0].isDead }.map {
            EventHistory.Event(path: tree.path(of: $0), mustScanSubDirs: false)
        }
        #expect(Incremental.applyTracked(all, to: tree, options: ScanOptions(), report: &again) == nil)
        #expect(Totals(tree).sameRoot(as: Totals(full)), "\(label) again", sourceLocation: sourceLocation)
        for e in tree.hardlinks.table.values {
            #expect(e.owner >= 0 && !tree.nodes[Int(e.owner)].isDead, "\(label)", sourceLocation: sourceLocation)
            #expect(e.others.allSatisfy { !tree.nodes[Int($0)].isDead }, "\(label)", sourceLocation: sourceLocation)
        }
        for e in tree.clones.table.values {
            #expect(e.owner >= 0 && !tree.nodes[Int(e.owner)].isDead, "\(label)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("Registry index in updates")
struct RegistryIndexUpdateTests {
    @Test("hard links: the owner's link is deleted, then another link")
    func deletes() throws {
        try withSnapshotDir { dir in
            try Fixture.with("index-del") { f in
                try f.mk("a/f", bytes: 40_000)
                try f.link("a/f", to: "b/l1")
                try f.link("a/f", to: "c/l2")
                try f.mk("b/plain", bytes: 5000)
                try updateMatchesFullScan(f, snapshotDir: dir, events: ["a"]) { try f.remove("a/f") }
                try updateMatchesFullScan(f, snapshotDir: dir, events: ["b"]) { try f.remove("b/l1") }
            }
        }
    }

    @Test("hard links: the directories holding the owner and another link are renamed")
    func renames() throws {
        try withSnapshotDir { dir in
            try Fixture.with("index-ren") { f in
                try f.mk("a/f", bytes: 40_000)
                try f.link("a/f", to: "b/l1")
                try f.link("a/f", to: "c/deep/l2")
                try updateMatchesFullScan(f, snapshotDir: dir, events: [""]) {
                    try f.rename("a", to: "a2")
                    try f.rename("b", to: "b2")
                }
                try updateMatchesFullScan(f, snapshotDir: dir, events: ["c"]) { try f.rename("c/deep", to: "c/moved") }
            }
        }
    }

    @Test("hard links spanning directories: a subtree holding the owner is removed")
    func spanning() throws {
        try withSnapshotDir { dir in
            try Fixture.with("index-span") { f in
                for i in 0..<6 {
                    try f.mk("src/x\(i)/y/f", bytes: 20_000 + i * 4096)
                    try f.link("src/x\(i)/y/f", to: "p/q\(i)/l")
                    try f.link("src/x\(i)/y/f", to: "r/l\(i)")
                }
                try updateMatchesFullScan(f, snapshotDir: dir, events: [""]) { try f.remove("src") }
                try updateMatchesFullScan(f, snapshotDir: dir, events: ["p"], mustScanSubDirs: true) {
                    try f.move("p/q0/l", to: "r/moved")
                    try f.remove("p/q1")
                }
            }
        }
    }

    @Test("clone families spanning directories: original deleted, a member's directory renamed, another removed")
    func clones() throws {
        try withSnapshotDir { dir in
            try Fixture.with("index-clone") { f in
                try f.mk("x/orig", bytes: 300_000)
                try f.clone("x/orig", to: "y/c1")
                try f.clone("x/orig", to: "z/sub/c2")
                try f.clone("x/orig", to: "w/c3")
                try f.mk("x/other", bytes: 200_000)
                try f.clone("x/other", to: "w/o1")
                try updateMatchesFullScan(f, snapshotDir: dir, events: ["x"]) { try f.remove("x/orig") }
                try updateMatchesFullScan(f, snapshotDir: dir, events: [""]) {
                    try f.rename("y", to: "y2")
                    try f.remove("z")
                }
                try updateMatchesFullScan(f, snapshotDir: dir, events: ["w"]) { try f.remove("w/o1") }
            }
        }
    }
}
