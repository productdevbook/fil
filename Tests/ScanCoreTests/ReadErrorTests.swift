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
            data[q + 1] = 0xD8  // U+D800, a lone high surrogate
            try data.write(to: URL(fileURLWithPath: image.path))
            guard image.attach(at: box.path("mnt")) else { try Test.cancel("hdiutil attach failed") }

            var st = stat()
            #expect(lstat(box.path("mnt"), &st) == 0)
            let reader = DirReader(DirReader.Config(rootDev: st.st_dev, options: ScanOptions()))
            defer { reader.deallocate() }
            var links = LinkBatch(keepNames: false)
            let out = reader.read(box.path("mnt"), links: &links)
            let raw = Array("longname_ab".utf8) + [0xED, 0xA0, 0x80]
            #expect(out.rawChildDirs.map(\.bytes) == [raw])
            let k = try #require(out.rawChildDirs.first?.index)
            #expect(out.childDirs[k] == "longname_ab\u{FFFD}\u{FFFD}\u{FFFD}")
            #expect(Set(out.childDirs) == ["plain", out.childDirs[k]])

            // Its bytes do not open it (the kernel cannot look the name up), yet it exists: kept unreadable, not
            // dropped as gone.
            let tree = try Scanner.scan(box.path("mnt"))
            let id = try #require(tree.node(at: box.path("mnt/" + out.childDirs[k])))
            #expect(tree.nodes[id].unreadable)
            #expect(tree.rawNames[Int32(id)] == raw)
            #expect(tree.stats.openErrors == 1)
        }
    }

    @Test("an update tells apart raw names whose display forms are the same")
    func collidingDisplayNames() throws {
        guard DiskImage.isAvailable else { try Test.cancel("no hdiutil") }
        try Fixture.with("fat") { box in
            guard let image = DiskImage(emptyMegabytes: 20, fs: "MS-DOS", at: box.path("fat.dmg")) else {
                try Test.cancel("hdiutil create failed")
            }
            defer { image.detach() }
            try box.mkdir("mnt")
            guard image.attach(at: box.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
            try box.mkdir("mnt/longname_abq")
            try box.mkdir("mnt/longname_abr")
            image.detach()
            // Both long names end in a different lone surrogate (U+D800, U+D801): different bytes, same display form.
            var data = try Data(contentsOf: URL(fileURLWithPath: image.path))
            let needle = Data("ame_ab".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            var from = data.startIndex
            var patched = 0
            while let at = data.range(of: needle, in: from..<data.endIndex) {
                let q = at.lowerBound - 14 + 28
                if data[q] == UInt8(ascii: "q") || data[q] == UInt8(ascii: "r") {
                    let low: UInt8 = data[q] == UInt8(ascii: "q") ? 0x00 : 0x01
                    data[q] = low
                    data[q + 1] = 0xD8
                    patched += 1
                }
                from = at.upperBound
            }
            try #require(patched == 2)
            try data.write(to: URL(fileURLWithPath: image.path))
            guard image.attach(at: box.path("mnt")) else { try Test.cancel("hdiutil attach failed") }

            func rawChildren(_ tree: DiskTree) -> Set<[UInt8]> {
                Set(tree.nodes.indices.filter { tree.nodes[$0].parent == 0 }.compactMap { tree.rawNames[Int32($0)] })
            }
            let tree = try Scanner.scan(box.path("mnt"))
            let both = rawChildren(tree)
            #expect(both.count == 2)
            // As if the second folder had appeared after the snapshot: drop it, then re-read the root.
            let second = try #require(tree.nodes.indices.last { tree.nodes[$0].parent == 0 })
            tree.nodes[second].parent = DirNode.dead
            tree.compact()
            tree.syncLinks()
            #expect(rawChildren(tree).count == 1)
            var report = UpdateReport()
            #expect(
                Incremental.applyTracked(
                    [EventHistory.Event(path: box.path("mnt"), mustScanSubDirs: false)],
                    to: tree, options: ScanOptions(), report: &report) == nil)
            #expect(rawChildren(tree) == both)
            #expect(report.dirsRemoved == 0)
        }
    }

    /// APFS keeps one of two canonically equal names, so the tree is given an NFC name for a folder that is NFD on disk:
    /// to the update diff that is another folder, as an NFC and an NFD folder side by side on SMB or NFS would be.
    @Test("children are matched by bytes, so NFC and NFD forms of a name are different folders")
    func normalizationForms() throws {
        let nfd = "e\u{301}", nfc = "\u{E9}"
        #expect(nfd == nfc && !nfd.utf8.elementsEqual(nfc.utf8))
        try Fixture.with { f in
            try f.mk("x/\(nfd)/file", bytes: 100_000)
            try f.mk("x/plain/file", bytes: 1000)
            let tree = try Scanner.scan(f.root)
            // A path typed or reported in the other form still finds the folder.
            let id = try #require(tree.node(at: f.path("x/\(nfc)")))
            #expect(tree.nodes[id].name.utf8.elementsEqual(nfd.utf8))
            tree.nodes[id].name = nfc
            var report = UpdateReport()
            #expect(
                Incremental.applyTracked(
                    [EventHistory.Event(path: f.path("x"), mustScanSubDirs: false)],
                    to: tree, options: ScanOptions(), report: &report) == nil)
            let x = try #require(tree.node(at: f.path("x")))
            var names: [String] = []
            tree.forEachChild(of: Int32(x)) { names.append(tree.nodes[Int($0)].name) }
            #expect(names.contains { $0.utf8.elementsEqual(nfd.utf8) })
            #expect(!names.contains { $0.utf8.elementsEqual(nfc.utf8) })
            #expect(report.dirsRemoved == 1)
            #expect(Totals(tree).sameRoot(as: Totals(try Scanner.scan(f.root))))
        }
    }

    @Test("an update keeps a raw-named folder that its bytes do not open, in a re-read and in a rescan")
    func updateKeepsUnopenableRawName() throws {
        for subtree in [false, true] {
            try Fixture.with { f in
                try f.mk("real/a", bytes: 200_000)
                let tree = try Scanner.scan(f.root)
                let id = try #require(tree.node(at: f.path("real")))
                tree.nodes[id].name = badDisplay
                tree.rawNames[Int32(id)] = Array("no such name".utf8)
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.path(badDisplay), mustScanSubDirs: subtree)],
                        to: tree, options: ScanOptions(), report: &report) == nil)
                let kept = try #require(tree.node(at: f.path(badDisplay)), "subtree \(subtree)")
                #expect(tree.nodes[kept].unreadable, "subtree \(subtree)")
                #expect(report.dirsRemoved == 0, "subtree \(subtree)")
            }
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
                let idAt = tag.upperBound + 8 + 4  // after size u64 and count u32
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
                let failure = Incremental.applyTracked(
                    [
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
            let givenUp = try Scanner.scan(
                f.root, options: faulty { $0.bulk[f.path("x")] = [EINTR, EINTR, EINTR, EINTR] })
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

    @Test("an incomplete update re-read keeps the children it did not list and adds the new ones it saw")
    func incompleteRereadKeepsChildren() throws {
        let faults: [(String, (Fixture) -> ScanOptions)] = [
            ("bulk", { f in faulty { $0.bulk[f.path("x")] = [EIO] } }),
            ("mid", { f in faulty { $0.bulk[f.path("x")] = [0, EIO] } }),
            ("entry", { f in faulty { $0.entryError.insert(f.path("x")) } }),
        ]
        for (label, options) in faults {
            try Fixture.with { f in
                try f.mk("x/c1/file", bytes: 100_000)
                try f.mk("x/c2/file", bytes: 200_000)
                let tree = try Scanner.scan(f.root)
                try f.mk("x/c3/file", bytes: 300_000)
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.path("x"), mustScanSubDirs: false)],
                        to: tree, options: options(f), report: &report) == nil)
                let x = try #require(tree.node(at: f.path("x")))
                #expect(tree.nodes[x].incomplete, "\(label)")
                #expect(report.dirsRemoved == 0, "\(label)")
                for c in ["c1", "c2"] {
                    let id = try #require(tree.node(at: f.path("x/" + c)), "\(label) \(c)")
                    #expect(tree.nodes[id].totalFiles == 1, "\(label) \(c)")
                }
                if label != "bulk" {
                    // Seen in the listing (the injected error hides only the first entry, never all three).
                    let seen = ["c1", "c2", "c3"].filter { tree.node(at: f.path("x/" + $0)) != nil }
                    #expect(seen.count >= 2, "\(label)")
                }
            }
        }
    }

    @Test("an incomplete re-read drops an unlisted child that was renamed, so nothing is counted twice")
    func incompleteRereadDropsRenamed() throws {
        let faults: [(String, (Fixture) -> ScanOptions)] = [
            ("mid", { f in faulty { $0.bulk[f.path("x")] = [0, EIO] } }),
            ("entry", { f in faulty { $0.entryError.insert(f.path("x")) } }),
        ]
        for (label, options) in faults {
            try Fixture.with { f in
                try f.mk("x/b/file", bytes: 300_000)
                try f.mk("x/keep/file", bytes: 100_000)
                let tree = try Scanner.scan(f.root)
                try f.move("x/b", to: "x/d")
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.path("x"), mustScanSubDirs: false)],
                        to: tree, options: options(f), report: &report) == nil)
                #expect(tree.node(at: f.path("x/b")) == nil, "\(label)")
                #expect(tree.node(at: f.path("x/keep")) != nil, "\(label)")
                #expect(tree.root.totalAlloc <= f.duBytes(), "\(label)")
                if label == "mid" {
                    #expect(Totals(tree) == Totals(try Scanner.scan(f.root)), "\(label)")
                }
            }
        }
    }

    @Test("an incomplete folder is read again by the next update without any event, and the flag clears")
    func retriedWithoutEvent() throws {
        try Fixture.with { f in
            try f.mk("x/a", bytes: 100_000)
            try f.mk("x/sub/b", bytes: 50_000)
            let tree = try Scanner.scan(f.root, options: faulty { $0.bulk[f.path("x")] = [EIO] })
            let x = try #require(tree.node(at: f.path("x")))
            #expect(tree.nodes[x].incomplete)
            var report = UpdateReport()
            #expect(Incremental.applyTracked([], to: tree, options: ScanOptions(), report: &report) == nil)
            #expect(!tree.nodes.contains { !$0.isDead && $0.incomplete })
            #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
            #expect(tree.root.totalAlloc == f.duBytes())
        }
    }

    @Test("a parent flagged because it was renamed mid-scan is settled by the next update without any event")
    func parentLostRetried() throws {
        try Fixture.with { f in
            try f.mk("x/p/c/file", bytes: 100_000)
            let tree = try Scanner.scan(
                f.root,
                options: faulty {
                    $0.renameBeforeOpen[f.path("x/p/c")] = [f.path("x/p"), f.path("x/q")]
                })
            #expect(tree.nodes[try #require(tree.node(at: f.path("x/p")))].incomplete)
            var report = UpdateReport()
            #expect(Incremental.applyTracked([], to: tree, options: ScanOptions(), report: &report) == nil)
            #expect(tree.node(at: f.path("x/p")) == nil)
            #expect(tree.node(at: f.path("x/q/c")) != nil)
            #expect(!tree.nodes.contains { !$0.isDead && $0.incomplete })
            #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
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
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.path("y"), mustScanSubDirs: false)],
                        to: tree, options: faulty { $0.bulk[f.path("y")] = [EIO] },
                        report: &report) == nil)
                let y = try #require(tree.node(at: f.path("y")))
                #expect(tree.nodes[y].incomplete)
                #expect(
                    Incremental.applyTracked(
                        [
                            EventHistory.Event(path: f.path("x"), mustScanSubDirs: false),
                            EventHistory.Event(path: f.path("y"), mustScanSubDirs: true),
                        ],
                        to: tree, options: ScanOptions(), report: &report) == nil)
                #expect(!tree.nodes.contains { !$0.isDead && $0.incomplete })
                #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
            }
        }
    }
}

@Suite("A folder that disappears during a scan (#34)")
struct GoneDuringScanTests {
    @Test("a full scan drops it: not unreadable, still counted in openErrors")
    func fullScan() throws {
        try Fixture.with { f in
            try f.mk("x/gone/inner/file", bytes: 100_000)
            try f.mk("x/kept", bytes: 5000)
            try f.mk("y/file", bytes: 7000)
            let tree = try Scanner.scan(f.root, options: faulty { $0.removeBeforeOpen.insert(f.path("x/gone")) })
            #expect(!f.exists("x/gone"))
            #expect(tree.node(at: f.path("x/gone")) == nil)
            #expect(!tree.nodes.contains { $0.unreadable || $0.isDead || $0.incomplete })
            #expect(tree.stats.openErrors == 1)
            #expect(tree.root.totalDirs + 1 == 3)
            #expect(tree.root.totalAlloc == f.duBytes())
            #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
        }
    }

    @Test("a child gone because its parent was renamed mid-scan flags the parent incomplete")
    func parentRenamed() throws {
        try Fixture.with { f in
            try f.mk("x/p/c/file", bytes: 100_000)
            try f.mk("x/p/d/file", bytes: 100_000)
            let tree = try Scanner.scan(
                f.root,
                options: faulty {
                    $0.renameBeforeOpen[f.path("x/p/c")] = [f.path("x/p"), f.path("x/q")]
                    $0.renameBeforeOpen[f.path("x/p/d")] = [f.path("x/p"), f.path("x/q")]
                })
            #expect(f.exists("x/q/c") && !f.exists("x/p"))
            let p = try #require(tree.node(at: f.path("x/p")))
            #expect(tree.nodes[p].incomplete)
            #expect(tree.node(at: f.path("x/p/c")) == nil && tree.node(at: f.path("x/p/d")) == nil)
            #expect(!tree.nodes.contains { $0.unreadable })
        }
    }

    @Test("an update's rescan drops it too, and the tree matches a full scan")
    func updateRescan() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("x/a", bytes: 1000)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                try f.mk("x/new/gone/file", bytes: 100_000)
                try f.mk("x/new/kept", bytes: 3000)
                let tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.path("x"), mustScanSubDirs: false)],
                        to: tree, options: faulty { $0.removeBeforeOpen.insert(f.path("x/new/gone")) },
                        report: &report) == nil)
                #expect(tree.node(at: f.path("x/new/gone")) == nil)
                #expect(!tree.nodes.contains { !$0.isDead && $0.unreadable })
                #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
            }
        }
    }
}
