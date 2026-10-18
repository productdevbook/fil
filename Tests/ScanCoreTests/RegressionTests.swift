import CoreServices
import Darwin
import Dispatch
import Foundation
@testable import ScanCore
import Testing
import TestSupport

// Regression cases of #20 that the suites for #4 to #7 and #34 do not cover. Faults are the debug-only seams in
// `DirFaults`, which `swift test` builds in; a release build contains none of them.

@Suite("Cloud placeholders and other devices")
struct PlaceholderAndDeviceTests {
    /// `chflags(SF_DATALESS)` is silently ignored for a user (only the kernel sets the flag), so the entries are
    /// named in `DirFaults.dataless` and the reader reports them with the flag set.
    @Test("dataless files are counted by size only and dataless directories are not entered")
    func dataless() throws {
        try Fixture.with("dataless") { f in
            try f.mk("keep", bytes: 4096)
            try f.mk("stub", bytes: 50_000)
            try f.mk("cloud/inner/deep", bytes: 100_000)
            try f.mk("real/stub", bytes: 7000)
            var o = ScanOptions()
            o.faults.dataless = ["cloud", "stub"]
            let tree = try Scanner.scan(f.root, options: o)

            #expect(tree.stats.datalessDirs == 1)
            // Both files named "stub" are placeholders: logical bytes are reported, nothing is allocated.
            #expect(tree.stats.datalessLogical == 57_000)
            #expect(tree.node(at: f.path("cloud")) == nil, "a dataless directory has no node")
            #expect(tree.node(at: f.path("cloud/inner")) == nil)
            #expect(tree.node(at: f.path("real")) != nil)
            #expect(tree.root.totalAlloc == f.duBytes("keep"))
            #expect(tree.root.totalLogical == 4096)

            // Without the fault nothing is a placeholder.
            let plain = try Scanner.scan(f.root)
            #expect(plain.stats.datalessDirs == 0 && plain.stats.datalessLogical == 0)
            #expect(plain.root.totalAlloc == f.duBytes())

            // The counters survive a snapshot.
            try withSnapshotDir { dir in
                try Snapshot.save(tree, in: dir)
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(loaded.stats.datalessDirs == 1 && loaded.stats.datalessLogical == 57_000)
            }
        }
    }

    @Test("a volume mounted inside the root counts mountsSkipped; crossing devices enters it",
          .enabled(if: DiskImage.isAvailable, "hdiutil is not available"))
    func deviceCrossing() throws {
        try Fixture.with("cross-image") { box in
            try box.mk("src/rootfile", bytes: 400_000)
            try box.mk("src/sub/inner", bytes: 2_000_000)
            guard let image = DiskImage(from: box.path("src"), at: box.path("vol.dmg")) else {
                try Test.cancel("hdiutil create failed")
            }
            defer { image.detach() }
            try Fixture.with("cross") { f in
                try f.mk("data/a", bytes: 300_000)
                try f.mk("mnt/under", bytes: 100_000)
                guard image.attach(at: f.path("mnt")) else { try Test.cancel("hdiutil attach failed") }

                let plain = try Scanner.scan(f.root)
                #expect(plain.stats.mountsSkipped == 1)
                #expect(plain.node(at: f.path("mnt")) == nil)
                #expect(plain.root.totalAlloc == f.duBytes())

                let crossing = try Scanner.scan(f.root, options: ScanOptions(crossDevices: true))
                #expect(crossing.stats.mountsSkipped == 0)
                #expect(crossing.node(at: f.path("mnt/sub")) != nil)
                #expect(crossing.root.totalAlloc > plain.root.totalAlloc)

                // The mount point itself as the root is on its own device: nothing is skipped inside it.
                let inside = try Scanner.scan(f.path("mnt"))
                #expect(inside.stats.mountsSkipped == 0)
                #expect(inside.node(at: f.path("mnt/sub")) != nil)
            }
        }
    }
}

@Suite("Update failures (FSEvents)", .serialized)
struct UpdateFailureTests {
    /// A snapshot of `root`, loaded back as a tree ready for `Incremental.update`.
    private func loadedTree(_ root: String, in dir: URL) throws -> DiskTree {
        try Snapshot.save(try Scanner.scan(root), in: dir)
        return try #require(Snapshot.load(rootPath: root, privateSize: false, in: dir).tree)
    }

    private func failure(_ result: Result<UpdateReport, UpdateFailure>) -> UpdateFailure? {
        if case .failure(let why) = result { return why }
        return nil
    }

    @Test("rootUnreadable: the root is gone when the update starts")
    func rootUnreadable() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("r/a", bytes: 5000)
                let tree = try loadedTree(f.path("r"), in: dir)
                try f.remove("r")
                guard case .rootUnreadable(let e)? = failure(Incremental.update(tree)) else {
                    Issue.record("expected rootUnreadable")
                    return
                }
                #expect(e == ENOENT)
            }
        }
    }

    @Test("volumeChanged: the tree remembers another volume, or none")
    func volumeChanged() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a", bytes: 5000)
                let tree = try loadedTree(f.root, in: dir)
                let real = tree.volumeUUID
                tree.volumeUUID = "00000000-0000-0000-0000-000000000000"
                guard case .volumeChanged(let expected, let found)? = failure(Incremental.update(tree)) else {
                    Issue.record("expected volumeChanged")
                    return
                }
                #expect(expected == "00000000-0000-0000-0000-000000000000" && found == real)

                // A tree that does not know its volume is never trusted either.
                tree.volumeUUID = ""
                guard case .volumeChanged(let none, _)? = failure(Incremental.update(tree)) else {
                    Issue.record("expected volumeChanged for an unknown volume")
                    return
                }
                #expect(none.isEmpty)
            }
        }
    }

    @Test("historyUntrusted: a lost-history flag in the replay, one case per flag",
          arguments: [(kFSEventStreamEventFlagUserDropped, "UserDropped"),
                      (kFSEventStreamEventFlagKernelDropped, "KernelDropped"),
                      (kFSEventStreamEventFlagEventIdsWrapped, "EventIdsWrapped"),
                      (kFSEventStreamEventFlagRootChanged, "RootChanged")])
    func historyUntrusted(flag: Int, name: String) throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 5000)
                let tree = try loadedTree(f.root, in: dir)
                try f.mk("a/c", bytes: 100)
                var o = ScanOptions()
                o.faults.history.extraFlags = FSEventStreamEventFlags(flag)
                guard case .historyUntrusted(let flags, let path)? = failure(Incremental.update(tree, options: o)) else {
                    Issue.record("expected historyUntrusted")
                    return
                }
                #expect(flags == [name])
                #expect(!path.isEmpty)
                #expect(UpdateFailure.historyUntrusted(flags: flags, path: path).description.contains(name))
            }
        }
    }

    @Test("historyTimeout: HistoryDone never arrives")
    func historyTimeout() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 5000)
                let tree = try loadedTree(f.root, in: dir)
                var o = ScanOptions()
                o.faults.history.dropHistoryDone = true
                o.faults.history.historyLimit = 1
                let start = ContinuousClock.now
                guard case .historyTimeout(let seconds)? = failure(Incremental.update(tree, options: o)) else {
                    Issue.record("expected historyTimeout")
                    return
                }
                #expect(seconds == 1)
                #expect(ContinuousClock.now - start < .seconds(10))
            }
        }
    }

    @Test("barrierTimeout: the barrier event never arrives")
    func barrierTimeout() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 5000)
                let tree = try loadedTree(f.root, in: dir)
                var o = ScanOptions()
                o.faults.history.dropBarrier = true
                o.faults.history.barrierLimit = 1
                guard case .barrierTimeout(let seconds)? = failure(Incremental.update(tree, options: o)) else {
                    Issue.record("expected barrierTimeout")
                    return
                }
                #expect(seconds == 1)
            }
        }
    }

    @Test("after a failed update the tree is released and can be updated again")
    func failureReleasesTheTree() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 5000)
                let tree = try loadedTree(f.root, in: dir)
                var o = ScanOptions()
                o.faults.history.dropHistoryDone = true
                o.faults.history.historyLimit = 1
                #expect(failure(Incremental.update(tree, options: o)) != nil)
                // `acquire` traps when the tree is still held: reaching a second update is the check.
                #expect(failure(Incremental.update(tree)) == nil)
            }
        }
    }
}

@Suite("Snapshot header")
struct SnapshotHeaderTests {
    @Test("a version other than the current one is rejected, older or newer; a wrong mode byte is rejected")
    func versionAndMode() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 4096)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                let url = Snapshot.url(for: f.root, in: dir)
                let good = try Data(contentsOf: url)
                let version: UInt8 = good[4]
                func load() -> Snapshot.LoadFailure? {
                    if case .failure(let why) = Snapshot.load(rootPath: f.root, privateSize: false, in: dir) { return why }
                    return nil
                }
                #expect(load() == nil)
                for v: UInt8 in [0, version &- 1, version &+ 1, 255] {
                    var d: Data = good
                    d[4] = v
                    try d.write(to: url)
                    #expect(load() == .otherVersion(UInt32(v)), "version \(v)")
                }
                // Every mode byte but this file's own (0: neither private nor crossing).
                for mode: UInt8 in [1, 2, 3, 0x80] {
                    var d: Data = good
                    d[8] = mode
                    try d.write(to: url)
                    #expect(load() == .otherMode, "mode \(mode)")
                }
            }
        }
    }
}

@Suite("Registries under concurrency")
struct ConcurrentRegistryTests {
    @Test("hard links: of many directories claiming one inode at once, exactly one counts it")
    func hardlinkClaims() {
        let inodes = 500, dirs = 16
        let registry = HardlinkRegistry()
        let wins = (0..<inodes).map { _ in Counter() }
        DispatchQueue.concurrentPerform(iterations: dirs * inodes) { n in
            let dir = Int32(n % dirs + 1)
            // The same inode with the same sizes from every directory, in a scrambled order.
            let ino = UInt64((n / dirs * 7919) % inodes + 1)
            if registry.claim(ino, by: dir, alloc: 4096, logical: 100, cloneAware: 4096) { wins[Int(ino) - 1].add() }
        }
        #expect(wins.allSatisfy { $0.value == 1 })
        #expect(registry.table.count == inodes)
        #expect(registry.table.values.allSatisfy {
            $0.owner > 0 && $0.others.count == dirs - 1 && !$0.others.contains($0.owner)
        })
    }

    @Test("clones: a family claimed by many directories at once is counted once, with the dupes reported")
    func cloneClaims() {
        let families = 300, dirs = 12, alloc: Int64 = 8192
        let registry = CloneRegistry()
        let bytes = Counter(), dupes = Counter()
        DispatchQueue.concurrentPerform(iterations: dirs) { d in
            // Each directory holds one member of every family; the original sits in directory 1.
            let members = (0..<families).map { CloneMember(cloneID: UInt64($0 + 1), alloc: alloc, isOriginal: d == 0) }
            let r = registry.claim(members, by: Int32(d + 1))
            bytes.add(Int(r.bytes))
            dupes.add(r.dupes)
        }
        #expect(bytes.value == families * Int(alloc))
        #expect(dupes.value == families * (dirs - 1))
        #expect(registry.table.count == families)
        // Directory 1 holds the originals, so it is the preferred owner once the dust settles.
        _ = registry.preferOriginals()
        #expect(registry.table.values.allSatisfy { $0.owner == 1 && $0.original == 1 })
    }

    @Test("a parallel scan counts hard links once however the workers interleave")
    func parallelScan() throws {
        try Fixture.with("parallel") { f in
            for d in 0..<40 {
                try f.mk("d\(d)/own", bytes: 20_000)
                try f.link("d\(d)/own", to: "links/a\(d)/l1")
                try f.link("d\(d)/own", to: "links/b\(d)/l2")
            }
            let expected = f.duBytes()
            for _ in 0..<5 {
                let tree = try Scanner.scan(f.root, options: ScanOptions(threads: 8))
                #expect(tree.root.totalAlloc == expected)
                #expect(tree.stats.hardlinkDupes == 80)
            }
        }
    }
}

/// A counter several threads add to.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int = 1) {
        lock.lock()
        n += k
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}
