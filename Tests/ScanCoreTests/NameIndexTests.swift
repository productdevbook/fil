import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

// #17: a directory with many children gets a name index the first time a lookup walks more than
// `DiskTree.nameIndexThreshold` siblings. These tests compare every lookup with a walk of the sibling list, which is
// what `child(of:named:)` did before the index.

/// The lookup without an index: the first child in list order (newest first) whose name has the same bytes, else the
/// first canonically equal one.
private func walk(_ tree: DiskTree, _ id: Int32, _ name: some StringProtocol) -> Int32? {
    var exact: Int32?
    var equivalent: Int32?
    tree.forEachChild(of: id) { c in
        if exact == nil && tree.nodes[Int(c)].name.utf8.elementsEqual(name.utf8) { exact = c }
        if equivalent == nil && tree.nodes[Int(c)].name == name { equivalent = c }
    }
    return exact ?? equivalent
}

/// A tree that exists only in memory: the root and the given (parent, name) directories, in id order.
private func memoryTree(_ dirs: [(Int32, String)]) -> DiskTree {
    DiskTree(
        rootPath: "/nonexistent-fil-test", rootDev: 0, privateSize: false, crossDevices: false,
        nodes: [DirNode(parent: -1, name: "/nonexistent-fil-test")] + dirs.map { DirNode(parent: $0.0, name: $0.1) },
        eventId: 0, volumeUUID: "", scanStart: 0, hardlinks: HardlinkRegistry(), clones: CloneRegistry(), aliases: [])
}

/// Spellings that `String` equality treats as one name but that differ in their bytes.
private let aRing = ["\u{C5}", "A\u{30A}", "\u{212B}"]  // Å precomposed, decomposed, Angstrom sign
private let eAcute = ["caf\u{E9}", "cafe\u{301}"]  // NFC, NFD

@Suite("Name index")
struct NameIndexTests {
    /// Every query below, against a walk of the list: present names, other spellings, misses.
    private func expectSameAsWalk(
        _ tree: DiskTree, _ id: Int32, _ names: [String], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for n in names + names.map({ $0 + "-missing" }) + ["", "x", "C0", "c 1"] {
            let path = "/p/" + n + "/q"
            let sub = path.split(separator: "/", omittingEmptySubsequences: false)[2]
            #expect(
                tree.child(of: id, named: n) == walk(tree, id, n), "\(n.debugDescription)",
                sourceLocation: sourceLocation)
            #expect(
                tree.child(of: id, named: sub) == walk(tree, id, n), "\(n.debugDescription)",
                sourceLocation: sourceLocation)
        }
    }

    @Test("lookups in an indexed directory equal a walk of its children, also for canonically equal names")
    func collisions() {
        var dirs: [(Int32, String)] = (0..<100).map { (0, "c\($0)") }
        dirs += aRing.map { (0, $0) } + eAcute.map { (0, $0) }
        // One spelling only: a query in the other normalization falls back to it.
        dirs += [(0, "na\u{EF}ve-only-nfc"), (0, "re\u{301}sume\u{301}")]
        let tree = memoryTree(dirs)
        tree.syncLinks()
        #expect(!tree.hasNameIndex(of: 0))
        _ = tree.child(of: 0, named: "c0")  // the oldest child: the walk passes all of them
        #expect(tree.hasNameIndex(of: 0))
        expectSameAsWalk(tree, 0, dirs.map(\.1) + ["r\u{E9}sum\u{E9}", "nai\u{308}ve-only-nfc"])
        for (k, s) in aRing.enumerated() { #expect(tree.child(of: 0, named: s) == Int32(101 + k)) }
        #expect(tree.child(of: 0, named: eAcute[0]) == 104 && tree.child(of: 0, named: eAcute[1]) == 105)
        #expect(tree.child(of: 0, named: "r\u{E9}sum\u{E9}") == 107)
        #expect(tree.child(of: 0, named: "nai\u{308}ve-only-nfc") == 106)
    }

    @Test("a small directory is not indexed; a lookup that finds its name early still indexes a large one")
    func threshold() {
        let small = memoryTree((0..<DiskTree.nameIndexThreshold).map { (0, "s\($0)") })
        small.syncLinks()
        _ = small.child(of: 0, named: "nothing")
        #expect(!small.hasNameIndex(of: 0))
        let large = memoryTree((0..<200).map { (0, "s\($0)") })
        large.syncLinks()
        #expect(large.child(of: 0, named: "s199") == 200)  // the newest: found first, nothing walked
        #expect(!large.hasNameIndex(of: 0))
        #expect(large.child(of: 0, named: "s100") == 101)
        #expect(large.hasNameIndex(of: 0))
    }

    @Test("children added, removed and renamed in and out keep the index right, through growth and compact")
    func changes() {
        let n = 50
        var dirs: [(Int32, String)] = [(0, "big"), (0, "other")]
        dirs += (0..<n).map { (1, "c\($0)") }
        dirs += [(2, "x"), (2, "y")]
        let tree = memoryTree(dirs)
        tree.syncLinks()
        _ = tree.child(of: 1, named: "c0")
        #expect(tree.hasNameIndex(of: 1))
        // Rename big/c5 to other/c5 and other/x to big/x: each is a dead node plus a new one.
        let c5 = tree.child(of: 1, named: "c5")!
        let x = tree.child(of: 2, named: "x")!
        tree.nodes[Int(c5)].parent = DirNode.dead
        tree.nodes[Int(x)].parent = DirNode.dead
        tree.nodes.append(DirNode(parent: 2, name: "c5"))
        tree.nodes.append(DirNode(parent: 1, name: "x"))
        // Removed and added again under the same name: the new node is found, not the dead one.
        let c7 = tree.child(of: 1, named: "c7")!
        tree.nodes[Int(c7)].parent = DirNode.dead
        tree.nodes.append(DirNode(parent: 1, name: "c7"))
        // Enough new children to grow the table several times; NFC and NFD side by side among them.
        for k in 0..<500 { tree.nodes.append(DirNode(parent: 1, name: "n\(k)")) }
        for s in eAcute { tree.nodes.append(DirNode(parent: 1, name: s)) }
        tree.syncLinks()
        let names = (0..<n).map { "c\($0)" } + (0..<500).map { "n\($0)" } + eAcute + ["x", "y"]
        expectSameAsWalk(tree, 1, names)
        #expect(tree.child(of: 1, named: "c5") == nil)
        #expect(tree.child(of: 1, named: "x") != nil)
        #expect(tree.child(of: 1, named: "c7")! > c7)
        #expect(tree.child(of: 2, named: "c5") != nil && tree.child(of: 2, named: "x") == nil)
        // Compact renumbers every node and drops the indexes; the next lookups rebuild them.
        tree.compact()
        tree.syncLinks()
        #expect(!tree.hasNameIndex(of: 1))
        let big = Int32(tree.node(at: "/nonexistent-fil-test/big")!)
        expectSameAsWalk(tree, big, names)
        #expect(tree.hasNameIndex(of: big))
        #expect(tree.path(of: Int(tree.child(of: big, named: "n499")!)) == "/nonexistent-fil-test/big/n499")
    }

    @Test("names that are not UTF-8 are found by their display form, like the walk finds them")
    func rawNames() {
        // Two names whose bytes differ but whose display forms are the same (U+FFFD for the bad byte).
        var dirs: [(Int32, String)] = (0..<40).map { (0, "r\($0)") }
        dirs += [(0, "bad\u{FFFD}"), (0, "bad\u{FFFD}"), (0, "bad\u{FFFD}x")]
        let tree = memoryTree(dirs)
        tree.rawNames[41] = Array("bad".utf8) + [0xFF]
        tree.rawNames[42] = Array("bad".utf8) + [0xFE]
        tree.syncLinks()
        _ = tree.child(of: 0, named: "r0")
        #expect(tree.hasNameIndex(of: 0))
        expectSameAsWalk(tree, 0, dirs.map(\.1))
        #expect(tree.child(of: 0, named: "bad\u{FFFD}") == 42)
    }

    @Test("an update renames folders into and out of an indexed folder and matches a full scan")
    func updateRenames() throws {
        try Fixture.with("names") { f in
            for k in 0..<60 { try f.mk("big/c\(k)/f", bytes: 1000 + k) }
            try f.mk("other/x/f", bytes: 7000)
            try f.mk("big/\(eAcute[0])/f", bytes: 3000)
            let tree = try Scanner.scan(f.root)
            let big = Int32(try #require(tree.node(at: f.path("big"))))
            _ = tree.node(at: f.path("big/c0"))
            #expect(tree.hasNameIndex(of: big))
            try f.rename("big/c5", to: "other/c5")
            try f.rename("other/x", to: "big/x")
            try f.mk("big/c9/g", bytes: 5000)
            try f.mk("big/new/f", bytes: 100)
            var report = UpdateReport()
            let events = ["big", "other", "big/c9", "big/\(eAcute[1])"].map {
                EventHistory.Event(path: f.path($0), mustScanSubDirs: false)
            }
            #expect(Incremental.applyTracked(events, to: tree, options: ScanOptions(), report: &report) == nil)
            let full = try Scanner.scan(f.root)
            #expect(Totals(tree) == Totals(full), "incremental \(Totals(tree)) full \(Totals(full))")
            #expect(tree.root.totalAlloc == f.duBytes())
            #expect(tree.node(at: f.path("big/c5")) == nil && tree.node(at: f.path("other/c5")) != nil)
            #expect(tree.node(at: f.path("big/x")) != nil && tree.node(at: f.path("other/x")) == nil)
            #expect(tree.node(at: f.path("big/new")) != nil)
            // A path in the other normalization still finds the folder.
            #expect(tree.node(at: f.path("big/\(eAcute[1])")) == tree.node(at: f.path("big/\(eAcute[0])")))
        }
    }
}
