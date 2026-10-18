import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

/// Allocated bytes of one file, as du counts them.
private func allocated(_ path: String) -> Int64 {
    var st = stat()
    return lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : -1
}

@Suite("Clone-aware accounting")
struct CloneAccountingTests {
    @Test("a full-clone family is counted once; alloc stays du-compatible")
    func fullClonesCountedOnce() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 500_000)
            try f.clone("x/a", to: "y/b")
            try f.clone("x/a", to: "y/c")
            try f.clone("x/a", to: "z/deep/d")
            try f.mk("x/plain", bytes: 20_000)
            let a = allocated(f.path("x/a"))
            let tree = try Scanner.scan(f.root)
            #expect(tree.root.totalAlloc == f.duBytes())
            #expect(tree.root.totalCloneAware == tree.root.totalAlloc - 3 * a)
            #expect(tree.stats.cloneDupes == 3)
            // The family belongs to the directory of the original, whatever order the workers read in.
            let x = try #require(tree.node(at: f.path("x")))
            let y = try #require(tree.node(at: f.path("y")))
            #expect(tree.nodes[x].totalCloneAware == a + allocated(f.path("x/plain")))
            #expect(tree.nodes[y].totalCloneAware == 0)
            #expect(tree.nodes[y].totalAlloc == 2 * a)
        }
    }

    @Test("without the original in the tree, the clones still count once")
    func clonesWithoutOriginal() throws {
        try Fixture.with { f in
            try f.mk("src/a", bytes: 400_000)
            try f.clone("src/a", to: "in/b")
            try f.clone("src/a", to: "in/sub/c")
            let a = allocated(f.path("src/a"))
            let tree = try Scanner.scan(f.path("in"))
            #expect(tree.root.totalAlloc == 2 * a)
            #expect(tree.root.totalCloneAware == a)
        }
    }

    @Test("a modified clone shares only part of its blocks and is counted in full")
    func partialCloneCountedInFull() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 300_000)
            try f.clone("x/a", to: "y/b")
            try f.append("y/b", bytes: 100_000)
            let tree = try Scanner.scan(f.root)
            #expect(tree.root.totalAlloc == f.duBytes())
            // a is a family of its own (b no longer has its clone id); b counts its whole allocation.
            #expect(tree.root.totalCloneAware == tree.root.totalAlloc)
        }
    }

    @Test("a hard-linked clone counts once as a hard link")
    func hardLinkedClone() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 200_000)
            try f.clone("x/a", to: "y/b")
            try f.link("y/b", to: "z/b2")
            let a = allocated(f.path("x/a"))
            let tree = try Scanner.scan(f.root)
            #expect(tree.root.totalAlloc == f.duBytes())
            #expect(tree.stats.hardlinkDupes == 1)
            // b is not deduplicated as a clone: a's family once, b once.
            #expect(tree.root.totalCloneAware == 2 * a)
        }
    }

    @Test("--private keeps private bytes in alloc and still reports the clone-aware size")
    func privateMode() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 300_000)
            try f.clone("x/a", to: "y/b")
            let a = allocated(f.path("x/a"))
            let tree = try Scanner.scan(f.root, options: ScanOptions(privateSize: true))
            #expect(tree.root.totalAlloc == 0)
            #expect(tree.root.totalCloneAware == a)
        }
    }

    @Test("clone families survive a snapshot round trip and updates keep them")
    func snapshotKeepsFamilies() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("x/a", bytes: 300_000)
                try f.clone("x/a", to: "y/b")
                let tree = try Scanner.scan(f.root)
                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                #expect(Totals(loaded) == Totals(tree))
                #expect(loaded.clones.table.count == 1)
                #expect(loaded.clones.table.values.first?.original == Int32(try #require(loaded.node(at: f.path("x")))))
            }
        }
    }
}

@Suite("Stats across updates")
struct UpdateStatsTests {
    @Test("an update keeps the full scan's stats; its own counts go to the report")
    func updateKeepsFullScanStats() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("x/a", bytes: 1000)
                try f.mk("y/other", bytes: 10)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                let tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                // A denied folder found by the update: counted in the report and as an unreadable node, not in stats.
                try f.mk("y/locked/secret", bytes: 100)
                try f.chmod("y/locked", 0o000)
                defer { try? f.chmod("y/locked", 0o755) }
                var report = UpdateReport()
                let failure = Incremental.applyTracked([EventHistory.Event(path: f.path("y"), mustScanSubDirs: false)],
                                                       to: tree, options: ScanOptions(), report: &report)
                #expect(failure == nil)
                #expect(report.stats.openErrors == 1)
                #expect(tree.stats.openErrors == 0)
                #expect(tree.nodes[try #require(tree.node(at: f.path("y/locked")))].unreadable)
            }
        }
    }
}

@Suite("Clone originals cloned after the snapshot")
struct CloneAdoptionTests {
    @Test("an original whose directory got no event becomes the owner; the family counts once")
    func adoptWithoutEventOnOriginal() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("x/a", bytes: 300_000)
                try f.mk("y/other", bytes: 10)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                try f.clone("x/a", to: "y/b")
                let tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                // Only y is replayed, as if FSEvents had reported nothing for the original's directory.
                var report = UpdateReport()
                let failure = Incremental.applyTracked([EventHistory.Event(path: f.path("y"), mustScanSubDirs: false)],
                                                       to: tree, options: ScanOptions(), report: &report)
                #expect(failure == nil)
                let full = try Scanner.scan(f.root)
                #expect(Totals(tree) == Totals(full), "incremental \(Totals(tree)) full \(Totals(full))")
                #expect(tree.clones.table.values.first?.owner == Int32(try #require(tree.node(at: f.path("x")))))
            }
        }
    }

    @Test("an original in a directory the tree could not list is not adopted (it counts nothing there)")
    func noAdoptionByUnreadableDirectory() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("x/a", bytes: 300_000)
                try f.mk("y/other", bytes: 10)
                // Searchable but not listable: the scan cannot read x, yet a path lookup inside it works.
                try f.chmod("x", 0o300)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                try f.clone("x/a", to: "y/b")
                let tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                var report = UpdateReport()
                let failure = Incremental.applyTracked([EventHistory.Event(path: f.path("y"), mustScanSubDirs: false)],
                                                       to: tree, options: ScanOptions(), report: &report)
                #expect(failure == nil)
                let full = try Scanner.scan(f.root)
                #expect(Totals(tree) == Totals(full), "incremental \(Totals(tree)) full \(Totals(full))")
                #expect(tree.root.totalCloneAware > 0)
            }
        }
    }
}

@Suite("Clone registry")
struct CloneRegistryTests {
    @Test("ownership moves to the original's directory and back to a member when it is forgotten")
    func ownership() {
        let r = CloneRegistry()
        #expect(r.claim([CloneMember(cloneID: 7, alloc: 100, isOriginal: false)], by: 3).bytes == 100)
        #expect(r.claim([CloneMember(cloneID: 7, alloc: 100, isOriginal: true)], by: 2).bytes == 0)
        let moves = r.preferOriginals()
        #expect(moves.count == 1 && moves[0].from == 3 && moves[0].to == 2 && moves[0].alloc == 100)
        #expect(r.entry(7)?.owner == 2)
        r.forget { $0 == 2 }
        let orphans = r.resolveOrphans()
        #expect(orphans.count == 1 && orphans[0].dir == 3 && orphans[0].alloc == 100)
        r.forget { $0 == 3 }
        #expect(r.entry(7) == nil)
    }

    @Test("a re-read directory reclaims its own family without counting it twice")
    func reclaim() {
        let r = CloneRegistry()
        let m = CloneMember(cloneID: 9, alloc: 50, isOriginal: true)
        #expect(r.claim([m, CloneMember(cloneID: 9, alloc: 50, isOriginal: false)], by: 1) == (50, 1))
        r.forget { $0 == 1 }
        #expect(r.claim([m], by: 1).bytes == 50)
        #expect(r.resolveOrphans().isEmpty)
    }
}

@Suite("Firmlinks")
struct FirmlinkTests {
    let table = FirmlinkTable.parse("""
        /Users\tUsers
        /System/Library/Caches\tSystem/Library/Caches
        /usr/local\tusr/local
        bogus line
        """, dataRoot: "/System/Volumes/Data/")

    @Test("the table is parsed from the firmlinks file format")
    func parse() {
        #expect(table.dataRoot == "/System/Volumes/Data")
        #expect(table.links.map(\.source) == ["/Users", "/System/Library/Caches", "/usr/local"])
        #expect(table.links.map(\.target) == ["Users", "System/Library/Caches", "usr/local"])
    }

    @Test("only a scan covering both a firmlink and its data-volume twin skips the twin")
    func aliasesPerRoot() {
        #expect(table.aliases(for: "/").map(\.dataPath)
            == ["/System/Volumes/Data/System/Library/Caches", "/System/Volumes/Data/Users", "/System/Volumes/Data/usr/local"])
        #expect(table.aliases(for: "/System").map(\.dataPath) == ["/System/Volumes/Data/System/Library/Caches"])
        #expect(table.aliases(for: "/Users/code/work").isEmpty)
        #expect(table.aliases(for: "/System/Volumes/Data").isEmpty)
        #expect(table.aliases(for: "/System/Volumes/Data/Users").isEmpty)
        #expect(table.aliases(for: "/usr").isEmpty)
        #expect(FirmlinkTable.empty.aliases(for: "/").isEmpty)
    }

    @Test("events reported under the data volume map to the firmlink path")
    func eventTranslation() {
        let aliases = table.aliases(for: "/")
        #expect(Incremental.relativeComponents("/System/Volumes/Data/Users/code/x", prefixes: [""], aliases: aliases)
            == ["Users", "code", "x"])
        #expect(Incremental.relativeComponents("/System/Volumes/Data/Users", prefixes: [""], aliases: aliases) == ["Users"])
        // Not a firmlinked directory: stays under the data volume.
        #expect(Incremental.relativeComponents("/System/Volumes/Data/UsersX/y", prefixes: [""], aliases: aliases)
            == ["System", "Volumes", "Data", "UsersX", "y"])
        #expect(Incremental.relativeComponents("/System/Volumes/Data/mnt/z", prefixes: [""], aliases: aliases)
            == ["System", "Volumes", "Data", "mnt", "z"])
    }

    @Test("a scan of / or /System keeps data-volume events at their own path, whatever the prefix order")
    func dataVolumePrefixInsideRoot() {
        for (root, event, want) in [("/", "/System/Volumes/Data/mnt/z", ["System", "Volumes", "Data", "mnt", "z"]),
                                    ("/System", "/System/Volumes/Data/System/x", ["Volumes", "Data", "System", "x"])] {
            let prefixes = Incremental.rootPrefixes(root)
            for order in [prefixes, prefixes.reversed()] {
                #expect(Incremental.relativeComponents(event, prefixes: order).map { $0.map(String.init) } == want,
                        "root \(root) prefixes \(order)")
            }
        }
        // A root reached through a firmlink still maps events reported under the data volume.
        #expect(Incremental.relativeComponents("/System/Volumes/Data/Users/code/x",
                                               prefixes: Incremental.rootPrefixes("/Users/code"))
            .map { $0.map(String.init) } == ["x"])
    }

    @Test("a scan with an injected table counts the firmlinked directory once")
    func injectedTable() throws {
        try Fixture.with { f in
            // sys/Users plays the firmlink, data/Users its twin on the data volume (here a plain copy).
            try f.mk("sys/Users/u/file", bytes: 50_000)
            try f.mk("data/Users/u/file", bytes: 50_000)
            try f.mk("data/other/f", bytes: 30_000)
            let table = FirmlinkTable(dataRoot: f.path("data"), links: [.init(source: f.path("sys/Users"), target: "Users")])
            let options = ScanOptions(firmlinks: table)
            let tree = try Scanner.scan(f.root, options: options)
            #expect(tree.stats.firmlinksSkipped == 1)
            #expect(tree.node(at: f.path("data/Users")) == nil)
            #expect(tree.node(at: f.path("sys/Users/u")) != nil)
            #expect(tree.root.totalAlloc == f.duBytes() - f.duBytes("data/Users"))
            #expect(tree.root.totalFiles == 2)
            // Scans of either side alone are untouched.
            let data = try Scanner.scan(f.path("data"), options: options)
            #expect(data.stats.firmlinksSkipped == 0)
            #expect(data.root.totalAlloc == f.duBytes("data"))
            let sys = try Scanner.scan(f.path("sys"), options: options)
            #expect(sys.root.totalAlloc == f.duBytes("sys"))
        }
    }

    @Test("a snapshot taken with other firmlinks is not updated incrementally")
    func changedTableFallsBack() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("sys/Users/file", bytes: 1000)
                try f.mk("data/Users/file", bytes: 1000)
                let table = FirmlinkTable(dataRoot: f.path("data"), links: [.init(source: f.path("sys/Users"), target: "Users")])
                try Snapshot.save(try Scanner.scan(f.root, options: ScanOptions(firmlinks: table)), in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                #expect(loaded.aliases == table.aliases(for: f.root))
                guard case .failure(.firmlinksChanged) = Incremental.update(loaded, options: ScanOptions(firmlinks: .empty)) else {
                    Issue.record("expected firmlinksChanged")
                    return
                }
            }
        }
    }

    @Test("the running system's table covers /Users when there is a volume group")
    func systemTable() {
        let t = FirmlinkTable.system
        guard !t.links.isEmpty else { return }
        #expect(t.aliases(for: "/").contains { $0.source == "/Users" && $0.dataPath == t.dataRoot + "/Users" })
        #expect(t.aliases(for: NSHomeDirectory()).isEmpty)
    }
}
