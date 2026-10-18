import Foundation
import ScanCore
import Testing
import TestSupport

/// What the scan engine reports for a tree: root totals plus every live directory by path.
struct Totals: Equatable, CustomStringConvertible {
    var alloc: Int64, logical: Int64, files: Int64, dirs: Int64, cloneAware: Int64
    var perDir: [String: [Int64]]
    var unreadable: Set<String>

    init(_ tree: DiskTree) {
        let r = tree.root
        alloc = r.totalAlloc; logical = r.totalLogical; files = r.totalFiles; dirs = r.totalDirs + 1
        cloneAware = r.totalCloneAware
        perDir = [:]
        unreadable = []
        for i in tree.nodes.indices where !tree.nodes[i].isDead {
            let n = tree.nodes[i]
            perDir[tree.path(of: i)] = [n.totalAlloc, n.totalLogical, n.totalFiles, n.totalDirs, n.totalCloneAware]
            if n.unreadable { unreadable.insert(tree.path(of: i)) }
        }
    }

    /// The root's totals only. Which directory of a hard-linked file gets its bytes depends on scan order,
    /// so for those the per-directory split of two correct scans can differ.
    func sameRoot(as other: Totals) -> Bool {
        alloc == other.alloc && logical == other.logical && files == other.files && dirs == other.dirs
            && cloneAware == other.cloneAware
    }

    var description: String { "alloc=\(alloc) logical=\(logical) files=\(files) dirs=\(dirs) cloneAware=\(cloneAware)" }
}

/// Where a test keeps its snapshots: always an explicit private folder, never the user's cache.
func withSnapshotDir<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = try Fixture(label: "snapshots")
    defer { dir.remove() }
    return try body(URL(fileURLWithPath: dir.root, isDirectory: true))
}

@Suite("Full scan")
struct FullScanTests {
    @Test("sizes match du -skx exactly")
    func matchesDu() throws {
        try Fixture.with { f in
            try f.mk("a/one", bytes: 5000)
            try f.mk("a/b/two", bytes: 123_457)
            try f.mk("c/three", bytes: 1)
            try f.mkdir("empty/inner")
            try f.mk("many/f", bytes: 0)
            for i in 0..<200 { try f.mk("many/f\(i)", bytes: (i * 37) % 9000 + 1) }
            let tree = try Scanner.scan(f.root)
            #expect(tree.root.totalAlloc == f.duBytes())
            #expect(tree.root.totalFiles == 3 + 1 + 200)   // one, two, three, many/f, many/f0...f199
        }
    }

    @Test("a file is counted once however many hard links point to it")
    func hardLinksCountedOnce() throws {
        try Fixture.with { f in
            try f.mk("own/file", bytes: 40_000)
            try f.link("own/file", to: "peer/alias")
            let withLink = try Scanner.scan(f.root)
            #expect(withLink.root.totalAlloc == f.duBytes())
            #expect(withLink.stats.hardlinkDupes == 1)
            try f.remove("peer/alias")
            let without = try Scanner.scan(f.root)
            #expect(without.stats.hardlinkDupes == 0)
        }
    }

    @Test("a folder that cannot be read is counted in openErrors and left empty")
    func permissionDenied() throws {
        try Fixture.with { f in
            try f.mk("open/file", bytes: 10_000)
            try f.mk("locked/secret", bytes: 50_000)
            try f.chmod("locked", 0o000)
            let tree = try Scanner.scan(f.root)
            #expect(tree.stats.openErrors == 1)
            let id = try #require(tree.node(at: f.path("locked")))
            #expect(tree.nodes[id].unreadable)
            #expect(tree.nodes[id].totalFiles == 0)
            #expect(tree.nodes[id].totalAlloc < 50_000)
            #expect(tree.root.totalAlloc == f.duBytes())
            try f.chmod("locked", 0o755)
        }
    }

    @Test("symlinks are not followed")
    func symlinkNotFollowed() throws {
        try Fixture.with { f in
            try f.mk("real/big", bytes: 1_000_000)
            try f.mkdir("other")
            try f.symlink(f.path("real"), at: "other/link")
            let tree = try Scanner.scan(f.path("other"))
            #expect(tree.root.totalAlloc < 100_000)
            #expect(tree.root.totalDirs == 0)
        }
    }

    @Test("the snapshot round-trips through an explicit directory")
    func snapshotRoundTrip() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b/c", bytes: 4096)
                try f.mk("x", bytes: 77)
                let tree = try Scanner.scan(f.root)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir) == nil)
                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                #expect(Totals(loaded) == Totals(tree))
                #expect(loaded.eventId == tree.eventId)
                // A different mode or root is not a usable snapshot.
                #expect(Snapshot.load(rootPath: f.root, privateSize: true, in: dir) == nil)
                #expect(Snapshot.load(rootPath: f.root + "/a", privateSize: false, in: dir) == nil)
            }
        }
    }

    @Test("a corrupt snapshot is rejected, not trusted")
    func corruptSnapshot() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 100)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                let url = Snapshot.url(for: f.root, in: dir)
                let data = try Data(contentsOf: url)
                try data.prefix(data.count / 2).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir) == nil)
                try Data("garbage".utf8).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir) == nil)
            }
        }
    }
}
