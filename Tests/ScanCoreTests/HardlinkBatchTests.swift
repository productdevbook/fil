import Darwin
import Foundation
@testable import ScanCore
import Testing
import TestSupport

// #18: hard-link claims are batched per directory, so a directory costs at most one `HardlinkRegistry` lock
// (chapter 01 §4.4, §12). The lock counter exists only in debug builds.

@Suite("Hard links claimed per directory")
struct HardlinkBatchTests {
    /// `src` holds `files` files; each of `dirs` folders under `links` holds a link to every one of them.
    private func linkFarm(_ f: Fixture, files: Int, dirs: Int) throws {
        for i in 0..<files { try f.mk("src/f\(i)", bytes: 1_000 * (i % 7 + 1)) }
        for d in 0..<dirs {
            for i in 0..<files { try f.link("src/f\(i)", to: "links/d\(d)/l\(i)") }
        }
        try f.mk("plain/a", bytes: 5_000)
        try f.mk("plain/sub/b", bytes: 5_000)
    }

    #if DEBUG
        @Test("a full scan takes one registry lock per folder that holds hard links, none elsewhere")
        func fullScanLockCount() throws {
            try Fixture.with("lockcount") { f in
                let files = 40, dirs = 30
                try linkFarm(f, files: files, dirs: dirs)
                for threads in [1, 8] {
                    let tree = try Scanner.scan(f.root, options: ScanOptions(threads: threads))
                    // `src` and the 30 link folders; `links`, `plain`, `plain/sub` and the root hold none.
                    #expect(tree.hardlinks.debugLockCount.load(ordering: .relaxed) == dirs + 1)
                    #expect(tree.stats.hardlinkDupes == files * dirs)
                    #expect(tree.root.totalAlloc == f.duBytes())
                }
            }
        }

        @Test("an update re-read vets each folder's links under one lock; an unattributed link costs one more")
        func rereadLockCount() throws {
            try Fixture.with("lockcount-update") { f in
                let files = 25, dirs = 12
                try linkFarm(f, files: files, dirs: dirs)
                try f.mk("plain/old", bytes: 3_000)
                let tree = try Scanner.scan(f.root)
                // Born before the scan, linked after it: unknown to the registry, so an unattributed hard link.
                try f.link("plain/old", to: "links/d0/old-link")
                // Born after the scan: an ordinary new file.
                try f.mk("plain/new", bytes: 3_000)
                try f.link("plain/new", to: "links/d1/new-link")

                let paths = (0..<dirs).map { f.path("links/d\($0)") }
                tree.hardlinks.beginUpdate(cutoff: tree.scanStart, strict: true)
                defer { tree.hardlinks.endUpdate() }
                let before = tree.hardlinks.debugLockCount.load(ordering: .relaxed)
                let outcomes = Incremental.readDirectories(
                    paths, cPaths: paths.map { _ in nil }, tree: tree, options: ScanOptions(threads: 4))
                let locks = tree.hardlinks.debugLockCount.load(ordering: .relaxed) - before
                #expect(locks == dirs + 1)
                let expected = [files + 1, files + 1] + Array(repeating: files, count: dirs - 2)
                #expect(outcomes.map(\.deferredLinks.count) == expected)
                #expect(outcomes.allSatisfy { $0.files == 0 && $0.alloc == 0 })
                #expect(tree.hardlinks.unattributed)
                #expect(tree.hardlinks.unattributedPaths == [f.path("links/d0/old-link")])
            }
        }
    #endif

    @Test("hard links spread over many folders count once, in parallel and repeated, equal to du")
    func spreadLinksMatchDu() throws {
        try Fixture.with("spread") { f in
            let dirs = 60, perDir = 8
            var names = 0
            for d in 0..<dirs {
                for i in 0..<perDir {
                    try f.mk("s\(d)/f\(i)", bytes: 2_000 * (i + 1))
                    names += 1
                    // Three more links in other folders (one of them deep), and every fourth file twice in one.
                    for k in 1...3 {
                        let t = (d * 7 + i * 13 + k * 17) % dirs
                        let dir = k == 3 ? "deep/x\(t % 5)/y\(t)" : "t\(t)"
                        try f.link("s\(d)/f\(i)", to: "\(dir)/l\(d)-\(i)-\(k)")
                        names += 1
                    }
                    if i % 4 == 0 {
                        try f.link("s\(d)/f\(i)", to: "s\(d)/f\(i)-again")
                        names += 1
                    }
                }
            }
            let inodes = dirs * perDir
            let expected = f.duBytes()
            var logical: Int64?
            for run in 0..<6 {
                let tree = try Scanner.scan(f.root, options: ScanOptions(threads: run == 0 ? 1 : 8))
                #expect(tree.root.totalAlloc == expected, "run \(run)")
                #expect(tree.root.totalCloneAware == expected, "run \(run)")
                #expect(tree.root.totalFiles == Int64(inodes), "run \(run)")
                #expect(tree.stats.hardlinkDupes == names - inodes, "run \(run)")
                #expect(tree.hardlinks.table.count == inodes)
                #expect(tree.hardlinks.table.values.allSatisfy { !$0.others.contains($0.owner) })
                if let logical { #expect(tree.root.totalLogical == logical, "run \(run)") }
                logical = tree.root.totalLogical
            }
        }
    }
}
