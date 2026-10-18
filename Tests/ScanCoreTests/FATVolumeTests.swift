import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

/// A file system a volume is made with, `hdiutil create -fs` name and image size (FAT32 needs at least 64 MB).
struct VolumeKind: Sendable, CustomTestStringConvertible {
    let fs: String
    let megabytes: Int
    var testDescription: String { fs }
}

private let volumeKinds = [
    VolumeKind(fs: "MS-DOS", megabytes: 20),
    VolumeKind(fs: "MS-DOS FAT12", megabytes: 20),
    VolumeKind(fs: "MS-DOS FAT16", megabytes: 20),
    VolumeKind(fs: "MS-DOS FAT32", megabytes: 64),
    VolumeKind(fs: "ExFAT", megabytes: 20),
]

/// The volume's cluster size, `statfs.f_bsize`, whatever the file system.
private func clusterSize(_ path: String) -> Int64 {
    var fs = statfs()
    return statfs(path, &fs) == 0 ? Int64(fs.f_bsize) : 0
}

private func duBytes(_ path: String) -> Int64 { Fixture.duBlockBytes(path) }

/// Makes `kind` (an empty image outside the scanned folder), mounts it on `box/mnt` and runs `body` with the mount
/// point. Detached in a `defer`, also when `body` throws. Cancelled where the image cannot be made or mounted.
private func withVolume(_ kind: VolumeKind, _ body: (Fixture, String) throws -> Void) throws {
    guard DiskImage.isAvailable else { try Test.cancel("no hdiutil") }
    try Fixture.with("fat") { box in
        guard let image = DiskImage(emptyMegabytes: kind.megabytes, fs: kind.fs, at: box.path("vol.dmg")) else {
            try Test.cancel("hdiutil cannot make \(kind.fs)")
        }
        defer { image.detach() }
        try box.mkdir("mnt")
        guard image.attach(at: box.path("mnt")) else { try Test.cancel("hdiutil cannot attach \(kind.fs)") }
        try body(box, box.path("mnt"))
    }
}

/// Folders, empty files, files of one cluster and just over, and a folder that outgrows its first cluster.
private func populate(_ box: Fixture, unit: Int) throws {
    try box.mk("mnt/big", bytes: 307_203)
    try box.mk("mnt/tiny", bytes: 3)
    try box.mk("mnt/empty", bytes: 0)
    try box.mk("mnt/one", bytes: unit)
    try box.mk("mnt/over", bytes: unit + 1)
    try box.mk("mnt/under", bytes: unit - 1)
    try box.mk("mnt/a/b/c/deep", bytes: 5000)
    try box.mk("mnt/a/b/c/empty", bytes: 0)
    try box.mk("mnt/a/side", bytes: 1)
    try box.mkdir("mnt/emptydir")
    for i in 0..<150 { try box.mk("mnt/many/file-with-a-long-name-\(i)", bytes: i % 7 * 100) }
}

@Suite("FAT and exFAT volumes (#48)", .serialized)
struct FATVolumeTests {
    @Test("a full scan equals du, for the volume and for every folder", arguments: volumeKinds)
    func fullScanEqualsDu(_ kind: VolumeKind) throws {
        try withVolume(kind) { box, mnt in
            let unit = Int(clusterSize(mnt))
            try #require(unit > 0)
            try populate(box, unit: unit)
            let tree = try Scanner.scan(mnt)
            #expect(tree.root.totalAlloc == duBytes(mnt), "\(kind.fs) root, unit \(unit)")
            for sub in ["a", "a/b/c", "emptydir", "many"] {
                let id = try #require(tree.node(at: mnt + "/" + sub))
                #expect(tree.nodes[id].totalAlloc == duBytes(mnt + "/" + sub), "\(kind.fs) \(sub)")
            }
            // The data length is not rounded, and clone-aware bytes equal the allocation (no clones here).
            #expect(tree.root.totalLogical > 0 && tree.root.totalLogical < tree.root.totalAlloc)
            #expect(tree.root.totalCloneAware == tree.root.totalAlloc)
        }
    }

    @Test("the issue's volume: a 300 KB file, a 3-byte file and a folder", arguments: volumeKinds)
    func issueVolume(_ kind: VolumeKind) throws {
        try withVolume(kind) { box, mnt in
            try box.mk("mnt/f", bytes: 307_203)
            try box.mk("mnt/g", bytes: 3)
            try box.mk("mnt/sub/h", bytes: 1)
            let tree = try Scanner.scan(mnt)
            #expect(tree.root.totalAlloc == duBytes(mnt))
            #expect(tree.root.totalAlloc > 300_000)
            let sub = try #require(tree.node(at: mnt + "/sub"))
            #expect(tree.nodes[sub].totalAlloc == duBytes(mnt + "/sub"))
        }
    }

    @Test("the allocation unit rounds up each file, and a folder counts its own clusters", arguments: volumeKinds)
    func rounding(_ kind: VolumeKind) throws {
        try withVolume(kind) { box, mnt in
            let unit = Int64(clusterSize(mnt))
            try box.mk("mnt/d/zero", bytes: 0)
            try box.mk("mnt/d/exact", bytes: Int(unit))
            try box.mk("mnt/d/over", bytes: Int(unit) + 1)
            let tree = try Scanner.scan(mnt + "/d")
            let own = Int64(tree.root.totalAlloc) - 3 * unit  // exact (1) + over (2) + the folder's own space
            #expect(own >= unit, "a folder holds at least one cluster of its own: \(tree.root.totalAlloc) unit \(unit)")
            #expect(tree.root.totalAlloc == duBytes(mnt + "/d"))
            #expect(tree.root.totalLogical == unit + unit + 1)
        }
    }

    @Test("after a change, an update equals a full scan, which equals du", arguments: volumeKinds)
    func incremental(_ kind: VolumeKind) throws {
        try withSnapshotDir { dir in
            try withVolume(kind) { box, mnt in
                let unit = Int(clusterSize(mnt))
                try populate(box, unit: unit)
                try Snapshot.save(try Scanner.scan(mnt), in: dir)

                // A new file, a new nested folder, a removed folder, a file that grows by a cluster and a folder
                // that outgrows its clusters: the folders' own space changes too.
                try box.mk("mnt/added", bytes: unit + 1)
                try box.mk("mnt/new/n1/n2/leaf", bytes: 70_000)
                try box.remove("mnt/a")
                try box.append("mnt/one", bytes: unit)
                for i in 150..<400 { try box.mk("mnt/many/file-with-a-long-name-\(i)", bytes: 1) }

                let loaded = try #require(Snapshot.load(rootPath: mnt, privateSize: false, in: dir).tree)
                // FAT and exFAT have no FSEvents volume UUID, so an update is refused (the caller scans in full). Should a
                // volume ever allow it, the update must equal a full scan; either way the answer equals `du`.
                let result = Incremental.update(loaded)
                let full = try Scanner.scan(mnt)
                switch result {
                case .success:
                    #expect(
                        Totals(loaded) == Totals(full), "\(kind.fs): incremental \(Totals(loaded)) full \(Totals(full))"
                    )
                case .failure(let why):
                    if case .volumeChanged = why {} else { Issue.record("\(kind.fs): unexpected failure \(why)") }
                }
                #expect(full.root.totalAlloc == duBytes(mnt), "\(kind.fs) after the change")
                let many = try #require(full.node(at: mnt + "/many"))
                #expect(full.nodes[many].totalAlloc == duBytes(mnt + "/many"))
            }
        }
    }

    @Test(
        "a listing gives each child folder's own space, and a read with statSelf the folder's", arguments: volumeKinds)
    func listing(_ kind: VolumeKind) throws {
        try withVolume(kind) { box, mnt in
            try box.mk("mnt/sub/f", bytes: 10)
            try box.mk("mnt/file", bytes: 10)
            var st = stat()
            #expect(lstat(mnt, &st) == 0)
            let unit = clusterSize(mnt)
            let reader = DirReader(
                DirReader.Config(
                    rootDev: st.st_dev, options: ScanOptions(), allocUnit: Scanner.allocationUnit(of: mnt)))
            defer { reader.deallocate() }
            let out = reader.read(mnt, statSelf: true) { _, _, _, _, _ in true }
            #expect(out.childDirs == ["sub"])
            #expect(out.childAllocs.map(\.index) == [0])
            #expect(
                out.childAllocs.first?.alloc == duBytes(mnt + "/sub") - unit, "own space of sub = du minus its file")
            #expect(out.selfAlloc == Int64(st.st_blocks) * 512)
            #expect(out.alloc == unit)
        }
    }

    @Test("only FAT is rounded to its cluster size")
    func roundingOnlyOnFAT() throws {
        try withVolume(VolumeKind(fs: "MS-DOS", megabytes: 20)) { _, mnt in
            #expect(Scanner.allocationUnit(of: mnt) == clusterSize(mnt))
        }
        try withVolume(VolumeKind(fs: "ExFAT", megabytes: 20)) { _, mnt in
            #expect(Scanner.allocationUnit(of: mnt) == 0)
        }
        #expect(Scanner.allocationUnit(of: NSTemporaryDirectory()) == 0)
    }

    @Test("--cross-devices: a FAT32 volume inside an APFS folder gets its own cluster size and root space")
    func crossDevices() throws {
        let kind = VolumeKind(fs: "MS-DOS FAT32", megabytes: 64)
        guard DiskImage.isAvailable else { try Test.cancel("no hdiutil") }
        try Fixture.with("cross") { box in
            guard let image = DiskImage(emptyMegabytes: kind.megabytes, fs: kind.fs, at: box.path("vol.dmg")) else {
                try Test.cancel("hdiutil cannot make \(kind.fs)")
            }
            defer { image.detach() }
            try box.mk("root/apfs/file", bytes: 5000)
            try box.mkdir("root/mnt")
            guard image.attach(at: box.path("root/mnt")) else { try Test.cancel("hdiutil cannot attach") }
            try box.mk("root/mnt/tiny", bytes: 3)
            try box.mk("root/mnt/dir/inner/tiny2", bytes: 3)
            let root = box.path("root")
            let tree = try Scanner.scan(root, options: ScanOptions(crossDevices: true))
            #expect(tree.root.totalAlloc == Fixture.duBlockBytes(root, acrossVolumes: true))
            let mnt = try #require(tree.node(at: root + "/mnt"))
            #expect(tree.nodes[mnt].totalAlloc == Fixture.duBlockBytes(root + "/mnt"))
            #expect(
                tree.nodes[mnt].ownAlloc > 512, "the volume root's own space is counted: \(tree.nodes[mnt].ownAlloc)")
            // Without the option the volume is left out (du -x still counts the mount point's own 512 bytes).
            let plain = try Scanner.scan(root)
            #expect(plain.root.totalAlloc == tree.root.totalAlloc - tree.nodes[mnt].totalAlloc)
        }
    }

    @Test("an update's re-read counts a folder's own space also with --cross-devices")
    func rereadCrossDevices() throws {
        let kind = VolumeKind(fs: "MS-DOS", megabytes: 20)
        try withVolume(kind) { box, mnt in
            try box.mk("mnt/sub/f", bytes: 10)
            let options = ScanOptions(crossDevices: true)
            let tree = try Scanner.scan(mnt, options: options)
            let paths = [mnt, mnt + "/sub"]
            let outcomes = Incremental.readDirectories(paths, cPaths: [nil, nil], tree: tree, options: options)
            for (path, out) in zip(paths, outcomes) {
                var st = stat()
                #expect(lstat(path, &st) == 0)
                #expect(out.selfAlloc == Int64(st.st_blocks) * 512 && out.selfAlloc > 0, "\(path)")
            }
        }
    }

    @Test("APFS folders add nothing of their own")
    func apfsUnchanged() throws {
        try Fixture.with { f in
            try f.mk("a/b/file", bytes: 5000)
            try f.mkdir("empty")
            let tree = try Scanner.scan(f.root)
            #expect(tree.root.totalAlloc == f.duBytes())
            let empty = try #require(tree.node(at: f.path("empty")))
            #expect(tree.nodes[empty].totalAlloc == 0)
        }
    }
}
