import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

/// Scan options whose reads of `path` fail with `EIO` at the first `getattrlistbulk` call (debug builds only).
private func bulkEIO(_ path: String) -> ScanOptions {
    var o = ScanOptions()
    o.faults.bulk[path] = [EIO]
    return o
}

private func inode(_ path: String) -> UInt64 {
    var st = stat()
    return lstat(path, &st) == 0 ? st.st_ino : 0
}

@Suite("Folders keep their identity across updates (#49)")
struct FolderIdentityTests {
    @Test("every folder holds its file id, the root its st_ino; DirNode is 104 bytes")
    func scanRecordsIdentity() throws {
        #expect(MemoryLayout<DirNode>.stride == 104)
        try Fixture.with { f in
            try f.mk("a/b/c/file", bytes: 4096)
            try f.mkdir("a/empty")
            let tree = try Scanner.scan(f.root)
            for i in tree.nodes.indices {
                #expect(tree.nodes[i].fileID == inode(tree.path(of: i)), "\(tree.path(of: i))")
                #expect(tree.nodes[i].fileID != 0)
            }
        }
    }

    @Test("an incomplete re-read of the parent walks a folder recreated under the same name as new")
    func recreatedUnderIncompleteParent() throws {
        try Fixture.with { f in
            try f.mk("P/C/old", bytes: 300_000)
            try f.mk("P/C/deep/old", bytes: 200_000)
            try f.mk("P/keep/file", bytes: 10_000)
            let tree = try Scanner.scan(f.root)
            try f.remove("P/C")
            try f.mk("P/C/new", bytes: 40_000)
            try f.mk("P/C/other/new", bytes: 70_000)
            var report = UpdateReport()
            #expect(
                Incremental.applyTracked(
                    [EventHistory.Event(path: f.path("P"), mustScanSubDirs: false)],
                    to: tree, options: bulkEIO(f.path("P")), report: &report) == nil)
            let p = try #require(tree.node(at: f.path("P")))
            #expect(tree.nodes[p].incomplete)
            let c = try #require(tree.node(at: f.path("P/C")))
            #expect(tree.nodes[c].totalAlloc == f.duBytes("P/C"))
            #expect(tree.nodes[c].fileID == inode(f.path("P/C")))
            #expect(tree.node(at: f.path("P/C/deep")) == nil)
            #expect(tree.node(at: f.path("P/C/other")) != nil)
            // The unchanged sibling keeps its last result.
            let keep = try #require(tree.node(at: f.path("P/keep")))
            #expect(tree.nodes[keep].totalAlloc == f.duBytes("P/keep"))
        }
    }

    @Test("a firmlink, whose listed id is never its lstat inode, is kept by an incomplete re-read")
    func firmlinkKept() throws {
        try Fixture.with { f in
            try f.mk("P/C/file", bytes: 300_000)
            for firmlink in [false, true] {
                let tree = try Scanner.scan(f.root)
                let c = try #require(tree.node(at: f.path("P/C")))
                // As `/` lists `/Users`: the system volume's id, not the data-volume folder's inode.
                tree.nodes[c].fileID &+= 1
                var options = bulkEIO(f.path("P"))
                if firmlink {
                    options.firmlinks = FirmlinkTable.parse(f.path("P/C") + "\tP/C", dataRoot: "/nonexistent-fil")
                }
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.path("P"), mustScanSubDirs: false)],
                        to: tree, options: options, report: &report) == nil)
                #expect(report.dirsRemoved == (firmlink ? 0 : 1))
                #expect(tree.node(at: f.path("P/C")).map { $0 == c } == firmlink)
                #expect(tree.root.totalAlloc == f.duBytes())
            }
        }
    }

    @Test("a complete re-read of the parent walks a folder recreated under the same name as new")
    func recreatedUnderListedParent() throws {
        try Fixture.with { f in
            try f.mk("P/C/old", bytes: 300_000)
            try f.mk("P/C/deep/old", bytes: 200_000)
            let tree = try Scanner.scan(f.root)
            try f.remove("P/C")
            try f.mk("P/C/new", bytes: 40_000)
            var report = UpdateReport()
            #expect(
                Incremental.applyTracked(
                    [EventHistory.Event(path: f.path("P"), mustScanSubDirs: false)],
                    to: tree, options: ScanOptions(), report: &report) == nil)
            let c = try #require(tree.node(at: f.path("P/C")))
            #expect(tree.nodes[c].totalAlloc == f.duBytes("P/C"))
            #expect(Totals(tree) == Totals(try Scanner.scan(f.root)))
            #expect(tree.root.totalAlloc == f.duBytes())
        }
    }

    @Test("snapshot tag 7: round trip keeps every file id; without it ids are 0; a wrong count is corrupt")
    func snapshotSection() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("P/C/old", bytes: 300_000)
                try f.mk("P/D/file", bytes: 5000)
                let tree = try Scanner.scan(f.root)
                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(loaded.nodes.map(\.fileID) == tree.nodes.map(\.fileID))
                #expect(!loaded.nodes.contains { $0.fileID == 0 })

                // The section: tag u32 (7), size u64, count u32, then the ids.
                let url = Snapshot.url(for: f.root, in: dir)
                let good = try Data(contentsOf: url)
                let n = tree.nodes.count
                let head =
                    withUnsafeBytes(of: UInt32(7).littleEndian, Array.init)
                    + withUnsafeBytes(of: UInt64(4 + 8 * n).littleEndian, Array.init)
                let sectionStart = try #require(good.range(of: Data(head))).lowerBound
                let sectionEnd = sectionStart + 12 + 4 + 8 * n
                let countAt = sectionStart + 12
                #expect(Array(good[countAt..<countAt + 4]) == withUnsafeBytes(of: UInt32(n).littleEndian, Array.init))

                var wrongCount = good
                wrongCount.replaceSubrange(
                    countAt..<countAt + 4, with: withUnsafeBytes(of: UInt32(n - 1).littleEndian, Array.init))
                try wrongCount.write(to: url)
                guard case .failure(.corrupt) = Snapshot.load(rootPath: f.root, privateSize: false, in: dir) else {
                    Issue.record("a file-id count other than the node count was accepted")
                    return
                }

                // A format-6 file written before #49: no section, ids unknown, updates as before.
                var without = good
                without.removeSubrange(sectionStart..<sectionEnd)
                try without.write(to: url)
                let old = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(!old.nodes.contains { $0.fileID != 0 })
                try f.mk("P/E/file", bytes: 70_000)
                try f.append("P/D/file", bytes: 9000)
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [
                            EventHistory.Event(path: f.path("P"), mustScanSubDirs: false),
                            EventHistory.Event(path: f.path("P/D"), mustScanSubDirs: false),
                        ],
                        to: old, options: ScanOptions(), report: &report) == nil)
                #expect(report.dirsRemoved == 0)
                #expect(Totals(old) == Totals(try Scanner.scan(f.root)))
                // The children P's listing named are known from then on; P itself waits for its parent's next read.
                #expect(old.nodes[try #require(old.node(at: f.path("P")))].fileID == 0)
                for path in ["P/C", "P/D", "P/E"] {
                    let id = try #require(old.node(at: f.path(path)))
                    #expect(old.nodes[id].fileID == inode(f.path(path)), "\(path)")
                }
            }
        }
    }

    @Test("a mount point entered with --cross-devices has no identity: its listed id is the covered folder's")
    func mountPointUnknown() throws {
        guard DiskImage.isAvailable else { try Test.cancel("no hdiutil") }
        try Fixture.with("image") { box in
            try box.mk("src/inner/file", bytes: 200_000)
            guard let image = DiskImage(from: box.path("src"), at: box.path("vol.dmg")) else {
                try Test.cancel("hdiutil create failed")
            }
            defer { image.detach() }
            try Fixture.with("mount") { f in
                try f.mk("mnt/under", bytes: 100_000)
                try f.mk("plain/file", bytes: 5000)
                guard image.attach(at: f.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
                let options = ScanOptions(crossDevices: true)
                let tree = try Scanner.scan(f.root, options: options)
                let mnt = try #require(tree.node(at: f.path("mnt")))
                #expect(tree.nodes[mnt].fileID == 0)
                let inner = try #require(tree.node(at: f.path("mnt/inner")))
                #expect(tree.nodes[inner].fileID == inode(f.path("mnt/inner")))
                // A re-read of the parent leaves it unknown and keeps it.
                var report = UpdateReport()
                #expect(
                    Incremental.applyTracked(
                        [EventHistory.Event(path: f.root, mustScanSubDirs: false)],
                        to: tree, options: options, report: &report) == nil)
                #expect(report.dirsRemoved == 0)
                #expect(tree.node(at: f.path("mnt")) == mnt && tree.nodes[mnt].fileID == 0)
            }
        }
    }
}
