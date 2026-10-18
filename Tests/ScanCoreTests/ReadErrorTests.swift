import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

/// U+FFFD, what a name that is not valid UTF-8 shows as.
private let badDisplay = "f\u{FFFD}o"

@Suite("Directory names that are not UTF-8 (#6)")
struct RawNameTests {
    /// APFS, HFS+ and exFAT refuse such a name or escape it (`%FF`), but a FAT volume written elsewhere can hold a long
    /// name with a lone UTF-16 surrogate, which macOS lists as the bytes ED A0 80. The name is made by patching the
    /// long-name entry of a FAT image, then listed by the real kernel.
    @Test("a real listed name that is not UTF-8 keeps its bytes and gets a display form")
    func realListing() throws {
        guard DiskImage.isAvailable else { try Test.cancel("no hdiutil") }
        try Fixture.with("fat") { box in
            guard let image = DiskImage(emptyMegabytes: 20, fs: "MS-DOS", at: box.path("fat.dmg")) else {
                try Test.cancel("hdiutil create failed")
            }
            defer { image.detach() }
            try box.mkdir("mnt")
            guard image.attach(at: box.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
            try box.mk("mnt/longname_abq/file", bytes: 100_000)
            try box.mk("mnt/plain/file", bytes: 1000)
            image.detach()

            // Long-name entry: name2 (6 UTF-16 units) at byte 14, name3 at byte 28; "q" is the 12th unit, in name3.
            var data = try Data(contentsOf: URL(fileURLWithPath: image.path))
            let at = try #require(data.range(of: Data("ame_ab".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })))
            let q = at.lowerBound - 14 + 28
            #expect(data[q] == UInt8(ascii: "q") && data[q + 1] == 0)
            data[q] = 0x00
            data[q + 1] = 0xD8   // U+D800, a lone high surrogate
            try data.write(to: URL(fileURLWithPath: image.path))
            guard image.attach(at: box.path("mnt")) else { try Test.cancel("hdiutil attach failed") }

            var st = stat()
            #expect(lstat(box.path("mnt"), &st) == 0)
            let reader = DirReader(DirReader.Config(rootDev: st.st_dev, options: ScanOptions()))
            defer { reader.deallocate() }
            let out = reader.read(box.path("mnt")) { _, _, _, _, _ in true }
            let raw = Array("longname_ab".utf8) + [0xED, 0xA0, 0x80]
            #expect(out.rawChildDirs.map(\.bytes) == [raw])
            let k = try #require(out.rawChildDirs.first?.index)
            #expect(out.childDirs[k] == "longname_ab\u{FFFD}\u{FFFD}\u{FFFD}")
            #expect(Set(out.childDirs) == ["plain", out.childDirs[k]])
        }
    }

    /// No local file system lets a user create a name that is not UTF-8 and open it again (that takes a network volume),
    /// so this gives a real folder a display name that differs from its bytes, as a raw name has: everything must then
    /// open it, and what lies below it, by `rawNames`.
    @Test("rescans, re-reads and the snapshot use the raw bytes, not the display name")
    func walkByBytes() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("real/a", bytes: 200_000)
                try f.mk("real/inner/b", bytes: 300_000)
                try f.mk("plain/c", bytes: 5000)
                let reference = Totals(try Scanner.scan(f.root))
                let tree = try Scanner.scan(f.root)
                let id = try #require(tree.node(at: f.path("real")))
                tree.nodes[id].name = badDisplay
                tree.rawNames[Int32(id)] = Array("real".utf8)
                #expect(tree.cPath(of: id) == (f.path("real").utf8.map { CChar(bitPattern: $0) } + [0]))
                #expect(tree.cPath(of: 0) == nil)

                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(loaded.rawNames == tree.rawNames)

                // A malformed raw-name section (id 0, the root) makes the file corrupt.
                let url = Snapshot.url(for: f.root, in: dir)
                let good = try Data(contentsOf: url)
                var bad = good
                let tag = try #require(bad.range(of: Data([0x06, 0x00, 0x00, 0x80])))
                let idAt = tag.upperBound + 8 + 4   // after size u64 and count u32
                bad.replaceSubrange(idAt..<idAt + 4, with: [0, 0, 0, 0])
                try bad.write(to: url)
                guard case .failure(.corrupt) = Snapshot.load(rootPath: f.root, privateSize: false, in: dir) else {
                    Issue.record("a malformed raw-name section was accepted")
                    return
                }
                try good.write(to: url)

                // A re-read of the folder and a rescan of its subtree, both found by the display path.
                try f.mk("real/d", bytes: 70_000)
                try f.mk("real/inner/e", bytes: 90_000)
                var report = UpdateReport()
                let failure = Incremental.applyTracked([
                    EventHistory.Event(path: f.path(badDisplay), mustScanSubDirs: false),
                    EventHistory.Event(path: f.path(badDisplay + "/inner"), mustScanSubDirs: true),
                ], to: loaded, options: ScanOptions(), report: &report)
                #expect(failure == nil)
                #expect(loaded.stats.openErrors == 0)
                let full = Totals(try Scanner.scan(f.root))
                let got = Totals(loaded)
                #expect(got.sameRoot(as: full), "incremental \(got) full \(full)")
                #expect(got.perDir[f.path(badDisplay + "/inner")] == full.perDir[f.path("real/inner")])
                #expect(full.alloc == f.duBytes() && reference.alloc < full.alloc)
            }
        }
    }
}

/// Scan options with test faults (debug builds only).
private func faulty(_ change: (inout DirFaults) -> Void) -> ScanOptions {
    var o = ScanOptions()
    change(&o.faults)
    return o
}

@Suite("Partial directory reads (#7)")
struct IncompleteTests {
    @Test("a getattrlistbulk failure marks the directory incomplete, not unreadable")
    func bulkFailure() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 100_000)
            try f.mk("y/b", bytes: 5000)
            let tree = try Scanner.scan(f.root, options: faulty { $0.bulk[f.path("x")] = [EIO] })
            let x = try #require(tree.node(at: f.path("x")))
            #expect(tree.nodes[x].incomplete && !tree.nodes[x].unreadable)
            #expect(tree.nodes[x].ownFiles == 0)
            #expect(tree.stats.entryErrors == 1 && tree.stats.openErrors == 0)
            #expect(tree.nodes.indices.filter { tree.nodes[$0].incomplete } == [x])
        }
    }

    @Test("a failure after the first batch keeps what was read")
    func midDirectory() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 100_000)
            let tree = try Scanner.scan(f.root, options: faulty { $0.bulk[f.path("x")] = [0, EIO] })
            let x = try #require(tree.node(at: f.path("x")))
            #expect(tree.nodes[x].incomplete)
            #expect(tree.nodes[x].ownFiles == 1)
            #expect(tree.root.totalAlloc == f.duBytes())
        }
    }

    @Test("EINTR is retried up to three times in a row")
    func interrupted() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 100_000)
            let retried = try Scanner.scan(f.root, options: faulty { $0.bulk[f.path("x")] = [EINTR, EINTR, EINTR] })
            #expect(!retried.nodes.contains { $0.incomplete })
            #expect(retried.stats.entryErrors == 0)
            #expect(retried.root.totalAlloc == f.duBytes())
            let givenUp = try Scanner.scan(f.root, options: faulty { $0.bulk[f.path("x")] = [EINTR, EINTR, EINTR, EINTR] })
            let x = try #require(givenUp.node(at: f.path("x")))
            #expect(givenUp.nodes[x].incomplete && givenUp.stats.entryErrors == 1)
        }
    }

    @Test("an entry error drops the entry and marks the directory; a dropped folder is not walked")
    func entryError() throws {
        try Fixture.with { f in
            try f.mk("x/only/deep", bytes: 100_000)
            let tree = try Scanner.scan(f.root, options: faulty { $0.entryError.insert(f.path("x")) })
            let x = try #require(tree.node(at: f.path("x")))
            #expect(tree.nodes[x].incomplete)
            #expect(tree.node(at: f.path("x/only")) == nil)
            #expect(tree.stats.entryErrors == 1)
            #expect(tree.root.totalFiles == 0)
        }
    }

    @Test("the flag survives the snapshot and an update re-read sets or clears it")
    func snapshotAndUpdate() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("x/a", bytes: 100_000)
                try f.mk("y/b", bytes: 5000)
                try Snapshot.save(try Scanner.scan(f.root, options: faulty { $0.bulk[f.path("x")] = [EIO] }), in: dir)
                let tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                let x = try #require(tree.node(at: f.path("x")))
                #expect(tree.nodes[x].incomplete && !tree.nodes[x].unreadable)
                #expect(!tree.nodes[0].incomplete)

                var report = UpdateReport()
                // A re-read that fails again keeps it; a complete one clears it.
                #expect(Incremental.applyTracked([EventHistory.Event(path: f.path("y"), mustScanSubDirs: false)],
                                                 to: tree, options: faulty { $0.bulk[f.path("y")] = [EIO] },
                                                 report: &report) == nil)
                let y = try #require(tree.node(at: f.path("y")))
                #expect(tree.nodes[y].incomplete)
                #expect(Incremental.applyTracked([EventHistory.Event(path: f.path("x"), mustScanSubDirs: false),
                                                  EventHistory.Event(path: f.path("y"), mustScanSubDirs: true)],
                                                 to: tree, options: ScanOptions(), report: &report) == nil)
                #expect(!tree.nodes.contains { !$0.isDead && $0.incomplete })
                #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
            }
        }
    }
}
