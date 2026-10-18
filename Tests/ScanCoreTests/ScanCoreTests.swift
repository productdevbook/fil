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

extension Result {
    /// The loaded tree, or nil whatever the reason (tests that check the reason use the `Result`).
    var tree: Success? { try? get() }
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
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)
                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(Totals(loaded) == Totals(tree))
                #expect(loaded.eventId == tree.eventId)
                // A different mode or root is not a usable snapshot.
                #expect(Snapshot.load(rootPath: f.root, privateSize: true, in: dir).tree == nil)
                #expect(Snapshot.load(rootPath: f.root + "/a", privateSize: false, in: dir).tree == nil)
            }
        }
    }

    @Test("a snapshot is used only with its own device-crossing mode, in both directions")
    func snapshotCrossDevicesMode() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 4096)
                try Snapshot.save(try Scanner.scan(f.root, options: ScanOptions(crossDevices: true)), in: dir)
                #expect(Snapshot.load(rootPath: f.root, options: ScanOptions(), in: dir).tree == nil)
                #expect(Snapshot.load(rootPath: f.root, privateSize: true, crossDevices: true, in: dir).tree == nil)
                let crossing = try #require(Snapshot.load(rootPath: f.root, options: ScanOptions(crossDevices: true), in: dir).tree)
                #expect(crossing.crossDevices)

                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                let plain = try #require(Snapshot.load(rootPath: f.root, options: ScanOptions(), in: dir).tree)
                #expect(!plain.crossDevices)
                #expect(Snapshot.advance(crossing, in: dir))
                #expect(Snapshot.advance(plain, in: dir))

                // The mode byte is still checked: a file of the other mode under this mode's name is not used, and
                // advance never rewrites its header.
                let plainURL = Snapshot.url(for: f.root, in: dir)
                let crossingURL = Snapshot.url(for: f.root, crossDevices: true, in: dir)
                try FileManager.default.removeItem(at: crossingURL)
                try FileManager.default.copyItem(at: plainURL, to: crossingURL)
                #expect(Snapshot.load(rootPath: f.root, options: ScanOptions(crossDevices: true), in: dir).tree == nil)
                #expect(!Snapshot.advance(crossing, in: dir))
            }
        }
    }

    @Test("one snapshot per root and mode: each mode keeps its own file; the pre-#33 name is removed")
    func snapshotPerMode() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 4096)
                let modes: [ScanOptions] = [ScanOptions(), ScanOptions(privateSize: true),
                                            ScanOptions(crossDevices: true),
                                            ScanOptions(privateSize: true, crossDevices: true)]
                let names = Set(modes.map {
                    Snapshot.url(for: f.root, privateSize: $0.privateSize, crossDevices: $0.crossDevices, in: dir)
                        .lastPathComponent
                })
                #expect(names.count == 4)
                // FNV-1a 64 of "/", NUL, mode byte 0: fixed so that the name never changes by accident.
                #expect(Snapshot.url(for: "/", in: dir).lastPathComponent == "ef6d1917e79753ae.bin")

                let legacy = dir.appendingPathComponent(legacyName(f.root))
                try Data("old".utf8).write(to: legacy)
                // Removed by the first load that finds no snapshot under the new name, not by every save.
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)
                #expect(!FileManager.default.fileExists(atPath: legacy.path))
                for o in modes { try Snapshot.save(try Scanner.scan(f.root, options: o), in: dir) }
                for o in modes {
                    let t = try #require(Snapshot.load(rootPath: f.root, options: o, in: dir).tree)
                    #expect(t.privateSize == o.privateSize && t.crossDevices == o.crossDevices)
                }
            }
        }
    }

    @Test("format: version 5 is rejected; unknown sections are skipped unless marked must-understand")
    func snapshotFormatVersion() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 4096)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                let url = Snapshot.url(for: f.root, in: dir)
                let good = try Data(contentsOf: url)
                #expect(good[4] == 6 && good[8] == 0)

                var old = good
                old[4] = 5
                try old.write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)

                // The end marker is the last 12 bytes: insert a section before it.
                func withSection(tag: UInt32) -> Data {
                    var d = good.prefix(good.count - 12)
                    withUnsafeBytes(of: tag.littleEndian) { d.append(contentsOf: $0) }
                    withUnsafeBytes(of: UInt64(3).littleEndian) { d.append(contentsOf: $0) }
                    d.append(contentsOf: [1, 2, 3])
                    return d + good.suffix(12)
                }
                try withSection(tag: 99).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree != nil)
                try withSection(tag: 0x8000_0063).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)
                // A known section twice is corrupt.
                try withSection(tag: 4).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)
            }
        }
    }

    @Test("the full scan's stats and start survive a snapshot; a file without them has none")
    func snapshotStats() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("own/file", bytes: 40_000)
                try f.link("own/file", to: "peer/alias")
                try f.mk("locked/secret", bytes: 100)
                try f.chmod("locked", 0o000)
                defer { try? f.chmod("locked", 0o755) }
                let tree = try Scanner.scan(f.root)
                #expect(tree.stats.openErrors == 1 && tree.stats.hardlinkDupes == 1)
                #expect(tree.fullScanStart == tree.scanStart)
                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(loaded.stats.openErrors == 1 && loaded.stats.hardlinkDupes == 1)
                #expect(loaded.fullScanStart == tree.scanStart)

                // The stats section (tag 5, 72 bytes) is the last one before the 12-byte end marker.
                let url = Snapshot.url(for: f.root, in: dir)
                let good = try Data(contentsOf: url)
                let at = good.count - 12 - 12 - 72
                #expect(good[at] == 5)

                // A later writer may append counters: a longer section is read for its first 72 bytes, the rest skipped.
                func withStatsSize(_ size: UInt64, extra: Int) -> Data {
                    var d = good.prefix(at + 4)
                    withUnsafeBytes(of: size.littleEndian) { d.append(contentsOf: $0) }
                    d.append(contentsOf: good[(at + 12)..<(at + 12 + min(72, Int(size)))])
                    d.append(contentsOf: [UInt8](repeating: 0xAB, count: extra))
                    return d + good.suffix(12)
                }
                try withStatsSize(88, extra: 16).write(to: url)
                let longer = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(longer.stats.openErrors == 1 && longer.stats.hardlinkDupes == 1)
                #expect(longer.fullScanStart == tree.scanStart)
                // Shorter than the 9 values is corrupt.
                try withStatsSize(64, extra: 0).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)

                try (good.prefix(at) + good.suffix(12)).write(to: url)
                let bare = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(bare.fullScanStart == nil)
                #expect(bare.stats.openErrors == 0 && bare.stats.hardlinkDupes == 0)
                // Saved again, it still has none: no counters are made up.
                try Snapshot.save(bare, in: dir)
                #expect(try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree).fullScanStart == nil)
            }
        }
    }

    @Test("each reason a snapshot is not used has its own case")
    func loadFailureCases() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 4096)
                func load(_ root: String = f.root, privateSize: Bool = false) -> Snapshot.LoadFailure? {
                    if case .failure(let why) = Snapshot.load(rootPath: root, privateSize: privateSize, in: dir) {
                        return why
                    }
                    return nil
                }
                #expect(load() == .missing)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                #expect(load() == nil)
                let url = Snapshot.url(for: f.root, in: dir)
                let good = try Data(contentsOf: url)

                // Another mode's or another root's file under this name (as after a hash collision).
                let privateURL = Snapshot.url(for: f.root, privateSize: true, in: dir)
                try good.write(to: privateURL)
                #expect(load(privateSize: true) == .otherMode)
                try good.write(to: Snapshot.url(for: f.path("a"), in: dir))
                #expect(load(f.path("a")) == .otherRoot)

                var old = good
                old[4] = 5
                try old.write(to: url)
                #expect(load() == .otherVersion(5))
                try Data("garbage".utf8).write(to: url)
                #expect(load() == .notSnapshot)
                try good.prefix(good.count / 2).write(to: url)
                #expect(load() == .corrupt)
                try good.prefix(6).write(to: url)
                #expect(load() == .corrupt)
                // Shorter than the magic: a write that stopped early, not another kind of file.
                try good.prefix(3).write(to: url)
                #expect(load() == .corrupt)
                try Data().write(to: url)
                #expect(load() == .corrupt)

                // A file that exists but cannot be read is not "missing": it keeps its errno.
                try good.write(to: url)
                #expect(chmod(url.path, 0o000) == 0)
                defer { chmod(url.path, 0o644) }
                #expect(load() == .unreadable(errno: EACCES))
                #expect(Snapshot.LoadFailure.unreadable(errno: EACCES).description == "unreadable (Permission denied)")
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
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)
                try Data("garbage".utf8).write(to: url)
                #expect(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree == nil)
            }
        }
    }
}

/// The file name snapshots had before #33: FNV-1a 64 of the root path alone.
private func legacyName(_ rootPath: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in rootPath.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return String(h, radix: 16) + ".bin"
}
