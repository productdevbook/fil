import Foundation
import ScanCore
import Testing
import TestSupport

// Incremental updates replay FSEvents history from the real fseventsd. These tests do not sleep: `Incremental.update`
// makes a barrier event of its own and waits for it (2 s at most), so every change made before the call is
// replayed. They are the only tests that depend on the machine's fseventsd, hence the suite name: skip them with
// `swift test --skip FSEvents` where fseventsd is not trustworthy (some CI virtual machines).
// They run one at a time so that parallel file activity does not slow the barrier down.

/// One change the incremental update must replay exactly, as in scripts/verify.sh.
struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    /// Strict hard links may fall back to a full scan (an update that fails is not a wrong answer).
    let mayFallBack: Bool
    let setup: @Sendable (Fixture) throws -> Void
    let change: @Sendable (Fixture) throws -> Void
    var testDescription: String { name }
    /// Hard-link scenarios compare the root only (see `Totals.sameRoot`); so does a clone family without its original,
    /// which belongs to whichever member's directory claimed it first.
    var rootOnly: Bool { name.hasPrefix("hardlink") || name == "clone: delete the original" }

    func same(_ a: Totals, _ b: Totals) -> Bool { rootOnly ? a.sameRoot(as: b) : a == b }

    init(_ name: String, mayFallBack: Bool = false, setup: @escaping @Sendable (Fixture) throws -> Void,
         change: @escaping @Sendable (Fixture) throws -> Void) {
        self.name = name
        self.mayFallBack = mayFallBack
        self.setup = setup
        self.change = change
    }
}

let scenarios: [Scenario] = [
    Scenario("add files", setup: { f in
        try f.mk("base/a.bin", bytes: 5000); try f.mk("base/b.bin", bytes: 100)
    }, change: { f in
        try f.mk("base/c.bin", bytes: 70000); try f.mk("new/d.bin", bytes: 1); try f.mk("new/e.bin", bytes: 4096)
    }),
    Scenario("delete dir tree", setup: { f in
        for i in 1...5 { try f.mk("tree/sub\(i)/f", bytes: 9000) }
        try f.mk("tree/top", bytes: 2000); try f.mk("keep/k", bytes: 3000)
    }, change: { f in try f.remove("tree") }),
    Scenario("new nested dirs with files", setup: { f in try f.mk("root/x", bytes: 1000) }, change: { f in
        try f.mk("root/p/q/r/deep.bin", bytes: 12345); try f.mk("root/p/q/side", bytes: 7)
        try f.mk("root/p/q/r/s/t/u/v", bytes: 1); try f.mkdir("root/empty/inner")
    }),
    Scenario("grow existing file", setup: { f in
        try f.mk("g/file", bytes: 1000); try f.mk("g/other", bytes: 500)
    }, change: { f in try f.append("g/file", bytes: 1 << 20) }),
    Scenario("rename dir", setup: { f in
        try f.mk("old/a", bytes: 5000); try f.mk("old/sub/b", bytes: 3000)
    }, change: { f in try f.move("old", to: "renamed") }),
    Scenario("move file between dirs", setup: { f in
        try f.mk("src/m", bytes: 20000); try f.mk("dst/x", bytes: 10)
    }, change: { f in try f.move("src/m", to: "dst/m") }),
    Scenario("delete 1 of 1000 files", setup: { f in
        for i in 1...1000 { try f.mk("many/f\(i)", bytes: (i * 37) % 9000 + 1) }
    }, change: { f in try f.remove("many/f500") }),
    Scenario("hardlink: new link, old file", mayFallBack: true, setup: { f in
        try f.mk("orig/file", bytes: 40000); try f.mkdir("other")
    }, change: { f in try f.link("orig/file", to: "other/link") }),
    Scenario("hardlink: delete owner link", setup: { f in
        try f.mk("own/file", bytes: 40000); try f.link("own/file", to: "peer/alias")
    }, change: { f in try f.remove("own/file") }),
    Scenario("hardlink: delete peer link", setup: { f in
        try f.mk("own/file", bytes: 40000); try f.link("own/file", to: "peer/alias")
    }, change: { f in try f.remove("peer/alias") }),
    Scenario("hardlink: new file, 2 links", setup: { f in try f.mk("base/x", bytes: 100) }, change: { f in
        try f.mk("fresh/h1", bytes: 50000); try f.link("fresh/h1", to: "fresh/h2")
    }),
    Scenario("rapid changes, no pause", setup: { f in
        try f.mk("a/keep", bytes: 100); try f.mk("b/gone", bytes: 200); try f.mk("d/grow", bytes: 1000)
    }, change: { f in
        try f.mk("a/added", bytes: 300); try f.remove("b/gone"); try f.mk("c/new/file", bytes: 5000)
        try f.append("d/grow", bytes: 1 << 20)
    }),
    Scenario("hardlink: grow via link A", setup: { f in
        try f.mk("own/file", bytes: 40000); try f.link("own/file", to: "peer/alias")
    }, change: { f in try f.append("own/file", bytes: 1 << 20) }),
    Scenario("hardlink: grow via link B", setup: { f in
        try f.mk("own/file", bytes: 40000); try f.link("own/file", to: "peer/alias")
    }, change: { f in try f.append("peer/alias", bytes: 1 << 20) }),
    // APFS full clones: each family is counted once in the clone-aware size, whatever the update touched.
    Scenario("clone: new file and its clone", setup: { f in try f.mk("base/x", bytes: 100) }, change: { f in
        try f.mk("x/a", bytes: 300_000); try f.clone("x/a", to: "y/b")
    }),
    Scenario("clone: old file cloned into a new dir", setup: { f in try f.mk("x/a", bytes: 300_000) }, change: { f in
        try f.clone("x/a", to: "y/b")
    }),
    Scenario("clone: old file cloned into an old dir", setup: { f in
        try f.mk("x/a", bytes: 300_000); try f.mk("y/other", bytes: 10)
    }, change: { f in try f.clone("x/a", to: "y/b") }),
    Scenario("clone: delete the original", setup: { f in
        try f.mk("x/a", bytes: 300_000); try f.clone("x/a", to: "y/b"); try f.clone("x/a", to: "z/c")
    }, change: { f in try f.remove("x/a") }),
    Scenario("clone: delete a clone", setup: { f in
        try f.mk("x/a", bytes: 300_000); try f.clone("x/a", to: "y/b")
    }, change: { f in try f.remove("y/b") }),
    Scenario("clone: grow a clone", setup: { f in
        try f.mk("x/a", bytes: 300_000); try f.clone("x/a", to: "y/b")
    }, change: { f in try f.append("y/b", bytes: 1 << 20) }),
    Scenario("clone: move the original", setup: { f in
        try f.mk("x/a", bytes: 300_000); try f.clone("x/a", to: "y/b"); try f.mkdir("w")
    }, change: { f in try f.move("x/a", to: "w/a") }),
]

extension Fixture {
    /// An APFS clone of `from` at `to` (clonefile(2), like `cp -c`); parent directories are created.
    func clone(_ from: String, to: String) throws {
        try mkdir((to as NSString).deletingLastPathComponent)
        guard clonefile(path(from), path(to), 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum UpdateOutcome { case incremental(DiskTree, UpdateReport), fellBack(UpdateFailure) }

/// Saves a snapshot of `f`, applies `change`, loads the snapshot and replays the history, like `fil scan` does.
func scanChangeUpdate(_ f: Fixture, dir: URL, options: ScanOptions,
                      change: () throws -> Void) throws -> (outcome: UpdateOutcome, full: DiskTree) {
    let baseline = try Scanner.scan(f.root, options: options)
    try Snapshot.save(baseline, in: dir)
    try change()
    let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: options.privateSize, in: dir).tree)
    let outcome: UpdateOutcome
    switch Incremental.update(loaded, options: options) {
    case .success(let report): outcome = .incremental(loaded, report)
    case .failure(let why): outcome = .fellBack(why)
    }
    return (outcome, try Scanner.scan(f.root, options: options))
}

@Suite("Incremental update vs full scan (FSEvents)", .serialized)
struct IncrementalFSEventsTests {
    @Test("incremental result equals a fresh full scan and du", arguments: scenarios)
    func strictHardLinks(_ s: Scenario) throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try s.setup(f)
                let (outcome, full) = try scanChangeUpdate(f, dir: dir, options: ScanOptions()) { try s.change(f) }
                switch outcome {
                case .incremental(let tree, _):
                    #expect(s.same(Totals(tree), Totals(full)), "\(s.name): incremental \(Totals(tree)) full \(Totals(full))")
                case .fellBack(let why):
                    // Allowed only where the strict hard-link rule asks for a full scan.
                    #expect(s.mayFallBack, "\(s.name): update failed: \(why)")
                    if case .unattributedHardLink = why {} else { Issue.record("unexpected failure: \(why)") }
                }
                #expect(full.root.totalAlloc == f.duBytes(), "\(s.name): full scan vs du")
            }
        }
    }

    @Test("tolerant hard links give the same answers; an unknown old link is reported as uncertain",
          arguments: scenarios)
    func tolerantHardLinks(_ s: Scenario) throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try s.setup(f)
                let options = ScanOptions(strictHardlinks: false)
                let (outcome, full) = try scanChangeUpdate(f, dir: dir, options: options) { try s.change(f) }
                guard case .incremental(let tree, let report) = outcome else {
                    Issue.record("\(s.name): tolerant update failed: \(outcome)")
                    return
                }
                if s.mayFallBack {
                    // The new link to a file that predates the snapshot cannot be matched to its owner:
                    // counted and flagged, never silently wrong.
                    #expect(report.uncertainBytes > 0)
                    #expect(tree.uncertainBytes == report.uncertainBytes)
                    #expect(tree.root.totalAlloc >= full.root.totalAlloc)
                    #expect(tree.root.totalAlloc - full.root.totalAlloc <= report.uncertainBytes)
                } else {
                    #expect(report.uncertainBytes == 0)
                    #expect(s.same(Totals(tree), Totals(full)), "\(s.name): incremental \(Totals(tree)) full \(Totals(full))")
                }
            }
        }
    }

    @Test("strict mode: a new link to an old file falls back with the paths that could not be matched")
    func strictReportsUnattributedPaths() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("orig/file", bytes: 40000)
                try f.mkdir("other")
                let (outcome, _) = try scanChangeUpdate(f, dir: dir, options: ScanOptions()) {
                    try f.link("orig/file", to: "other/link")
                }
                guard case .fellBack(.unattributedHardLink(let paths)) = outcome else {
                    Issue.record("expected an unattributed hard link failure, got \(outcome)")
                    return
                }
                #expect(!paths.isEmpty)
            }
        }
    }

    @Test("an update with no changes replays nothing and the snapshot can advance")
    func noChanges() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 1234)
                let baseline = try Scanner.scan(f.root)
                try Snapshot.save(baseline, in: dir)
                var loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                guard case .success(var report) = Incremental.update(loaded) else {
                    Issue.record("update failed")
                    return
                }
                // `report.events` may count the fixture's own creation, which fseventsd numbers late (sometimes over
                // several updates). If that made the update re-read the tree, `advance` refuses it and the caller saves.
                for _ in 0..<10 where report.treeChanged {
                    #expect(!Snapshot.advance(loaded, in: dir))
                    try Snapshot.save(loaded, in: dir)
                    loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                    guard case .success(let next) = Incremental.update(loaded) else {
                        Issue.record("update failed")
                        return
                    }
                    report = next
                }
                try #require(!report.treeChanged, "fseventsd kept reporting the fixture's creation")
                #expect(loaded.eventId >= baseline.eventId)
                #expect(Snapshot.advance(loaded, in: dir))
                let again = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(again.eventId == loaded.eventId)
                #expect(Totals(again) == Totals(baseline))
            }
        }
    }

    @Test("two updates in a row stay exact")
    func chainedUpdates() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/keep", bytes: 500)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                var tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                for round in 1...3 {
                    try f.mk("a/r\(round)", bytes: 10_000 * round)
                    try f.mk("n\(round)/deep/x", bytes: 777)
                    guard case .success = Incremental.update(tree) else {
                        Issue.record("round \(round): update failed")
                        return
                    }
                    #expect(Totals(tree) == Totals(try Scanner.scan(f.root)), "round \(round)")
                    try Snapshot.save(tree, in: dir)
                    tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                }
            }
        }
    }

    @Test("a folder that loses its permissions is emptied and flagged, like a full scan does")
    func permissionRevoked() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("open/file", bytes: 10_000)
                try f.mk("site/inner/data", bytes: 60_000)
                let (outcome, full) = try scanChangeUpdate(f, dir: dir, options: ScanOptions()) {
                    try f.chmod("site/inner", 0o000)
                }
                guard case .incremental(let tree, _) = outcome else {
                    Issue.record("update failed: \(outcome)")
                    return
                }
                #expect(Totals(tree) == Totals(full))
                #expect(full.stats.openErrors == 1)
                let id = try #require(tree.node(at: f.path("site/inner")))
                #expect(tree.nodes[id].unreadable)
                try f.chmod("site/inner", 0o755)
            }
        }
    }

    @Test("a folder that becomes readable again is walked")
    func permissionRestored() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("open/file", bytes: 10_000)
                try f.mk("site/inner/data", bytes: 60_000)
                try f.chmod("site/inner", 0o000)
                let (outcome, full) = try scanChangeUpdate(f, dir: dir, options: ScanOptions()) {
                    try f.chmod("site/inner", 0o755)
                }
                guard case .incremental(let tree, _) = outcome else {
                    Issue.record("update failed: \(outcome)")
                    return
                }
                #expect(Totals(tree) == Totals(full))
                #expect(full.stats.openErrors == 0)
                let id = try #require(tree.node(at: f.path("site/inner")))
                #expect(!tree.nodes[id].unreadable)
                #expect(tree.nodes[id].totalFiles == 1)
            }
        }
    }

    @Test("a folder created and filled between the snapshot and the update is found")
    func newDeniedFolder() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/file", bytes: 100)
                let (outcome, full) = try scanChangeUpdate(f, dir: dir, options: ScanOptions()) {
                    try f.mk("fresh/locked/x", bytes: 9000)
                    try f.chmod("fresh/locked", 0o000)
                }
                guard case .incremental(let tree, _) = outcome else {
                    Issue.record("update failed: \(outcome)")
                    return
                }
                #expect(Totals(tree) == Totals(full))
                #expect(tree.nodes[try #require(tree.node(at: f.path("fresh/locked")))].unreadable)
                try f.chmod("fresh/locked", 0o755)
            }
        }
    }

    @Test("a disk image mounted inside the root is left out; the folder it covered is counted again after an unmount",
          .enabled(if: DiskImage.isAvailable, "hdiutil is not available"),
          arguments: [false, true])
    func mountAndUnmount(fullScanWhileMounted: Bool) throws {
        try withSnapshotDir { dir in
            try Fixture.with("mount") { f in try withImage { image in
                try f.mk("data/a", bytes: 300_000)
                try f.mk("mnt/under", bytes: 100_000)
                try f.mk("mnt/deep/x", bytes: 50_000)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)

                // FSEvents keeps no Mount event in its history: the update finds the mount in the mount table.
                guard image.attach(at: f.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
                let mounted = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                guard case .success = Incremental.update(mounted) else {
                    Issue.record("update after mount failed")
                    return
                }
                let full = try Scanner.scan(f.root)
                #expect(Totals(mounted) == Totals(full), "mounted: incremental \(Totals(mounted)) full \(Totals(full))")
                // A file at the root of the image must not be counted either: listings report a mount point with the
                // attributes of the directory underneath it.
                #expect(full.root.totalAlloc == f.duBytes(), "mounted: full scan vs du")
                #expect(full.stats.mountsSkipped == 1)
                #expect(mounted.node(at: f.path("mnt")) == nil)
                // Recorded by the update (the folder became a mount point) and by a full scan (its listing).
                #expect(mounted.mountPoints == [MountPoint(parent: 0, name: "mnt")])
                #expect(full.mountPoints == [MountPoint(parent: 0, name: "mnt")])
                try Snapshot.save(fullScanWhileMounted ? full : mounted, in: dir)

                // No event marks an unmount either: the recorded mount point is missing from the mount table.
                image.detach()
                let unmounted = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir).tree)
                #expect(unmounted.mountPoints == [MountPoint(parent: 0, name: "mnt")])
                guard case .success = Incremental.update(unmounted) else {
                    Issue.record("update after unmount failed")
                    return
                }
                let fullAfter = try Scanner.scan(f.root)
                let (a, b) = (Totals(unmounted), Totals(fullAfter))
                #expect(a == b, "unmounted: incremental \(a) full \(b)")
                #expect(fullAfter.root.totalAlloc == f.duBytes(), "unmounted: full scan vs du")
                #expect(unmounted.node(at: f.path("mnt/deep")) != nil)
                #expect(unmounted.mountPoints.isEmpty)
                // The update changed the tree without an event: the snapshot is rewritten, not advanced.
                #expect(!Snapshot.advance(unmounted, in: dir))
            } }
        }
    }

    @Test("a folder a volume is mounted over no longer counts what it held",
          .enabled(if: DiskImage.isAvailable, "hdiutil is not available"))
    func mountHidesContents() throws {
        try withSnapshotDir { dir in
            try Fixture.with("mount") { f in try withImage { image in
                try f.mk("data/a", bytes: 300_000)
                try f.mk("mnt/under", bytes: 100_000)
                try f.mk("mnt/deep/x", bytes: 50_000)
                let (outcome, full) = try scanChangeUpdate(f, dir: dir, options: ScanOptions()) {
                    guard image.attach(at: f.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
                }
                guard case .incremental(let tree, let report) = outcome else {
                    Issue.record("update failed: \(outcome)")
                    return
                }
                #expect(Totals(tree) == Totals(full), "incremental \(Totals(tree)) full \(Totals(full))")
                #expect(full.root.totalAlloc == f.duBytes())
                #expect(tree.node(at: f.path("mnt")) == nil)
                #expect(report.dirsRemoved == 2, "\(report)")
            } }
        }
    }

    @Test("a root given by its data-volume path sees the changes fseventsd reports under the firmlink path",
          .enabled(if: !FirmlinkTable.system.dataRoot.isEmpty, "no data volume"))
    func dataVolumeRootEvents() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("t/x/a", bytes: 300_000)
                let root = FirmlinkTable.system.dataRoot + f.path("t")
                try Snapshot.save(try Scanner.scan(root), in: dir)
                try f.mk("t/y/new", bytes: 50_000)
                let tree = try #require(Snapshot.load(rootPath: root, privateSize: false, in: dir).tree)
                guard case .success(let report) = Incremental.update(tree) else {
                    Issue.record("update failed")
                    return
                }
                #expect(report.treeChanged, "\(report)")
                #expect(Totals(tree) == Totals(try Scanner.scan(root)))
                #expect(tree.root.totalAlloc == f.duBytes("t"))
            }
        }
    }

    @Test("a data-volume root holding a firmlink target is never updated incrementally: a full scan always runs")
    func dataVolumeRootRefused() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("Users/a", bytes: 10_000)
                try f.mk("usr/local/b", bytes: 10_000)
                try f.mk("usr/bin/c", bytes: 10_000)
                try f.mk("other/d", bytes: 10_000)
                // The fixture plays the data volume: changes under a target would come under its firmlink path.
                let table = FirmlinkTable(dataRoot: f.root, links: [.init(source: "/Users", target: "Users"),
                                                                    .init(source: "/usr/local", target: "usr/local")])
                let options = ScanOptions(firmlinks: table)
                func update(_ relative: String) throws -> Result<UpdateReport, UpdateFailure> {
                    let root = f.path(relative)
                    try Snapshot.save(try Scanner.scan(root, options: options), in: dir)
                    let tree = try #require(Snapshot.load(rootPath: root, options: options, in: dir).tree)
                    return Incremental.update(tree, options: options)
                }
                // The data volume itself, and a folder that holds a target below it (usr holds usr/local).
                for relative in ["", "usr"] {
                    guard case .failure(.dataVolumeRoot) = try update(relative) else {
                        Issue.record("\(relative): expected dataVolumeRoot")
                        continue
                    }
                }
                // Inside a target (its firmlink spelling is a root prefix) or holding none: updated as before.
                for relative in ["usr/local", "Users", "other", "usr/bin"] {
                    if case .failure(.dataVolumeRoot) = try update(relative) { Issue.record("\(relative): refused") }
                }
                #expect(UpdateFailure.dataVolumeRoot.description
                    == "incremental updates are not supported for a data-volume root that holds firmlinked folders")
                #expect(!FirmlinkTable.system.holdsFirmlinkTargets("/Users/code"))
                #expect(!table.holdsFirmlinkTargets("/"))
            }
        }
    }

    @Test("a root given by its data-volume path that is replaced is not updated in place",
          .enabled(if: !FirmlinkTable.system.dataRoot.isEmpty, "no data volume"))
    func dataVolumeRootReplaced() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("t/x/a", bytes: 300_000)
                let root = FirmlinkTable.system.dataRoot + f.path("t")
                try Snapshot.save(try Scanner.scan(root), in: dir)
                try f.move("t", to: "t.old")
                try f.mk("t/b", bytes: 10_000)
                let tree = try #require(Snapshot.load(rootPath: root, privateSize: false, in: dir).tree)
                switch Incremental.update(tree) {
                case .failure(let why):
                    // RootChanged: a full scan follows.
                    if case .historyUntrusted = why {} else { Issue.record("unexpected failure: \(why)") }
                case .success(let report):
                    #expect(report.treeChanged, "\(report)")
                    #expect(Totals(tree) == Totals(try Scanner.scan(root)), "replaced root: \(Totals(tree))")
                }
            }
        }
    }

    @Test("a root given by its data-volume path finds mounts the mount table names by the firmlink path",
          .enabled(if: DiskImage.isAvailable, "hdiutil is not available"),
          .enabled(if: !FirmlinkTable.system.dataRoot.isEmpty, "no data volume"))
    func mountUnderDataVolumePath() throws {
        try withSnapshotDir { dir in
            try Fixture.with("mount") { f in try withImage { image in
                try f.mk("data/a", bytes: 300_000)
                try f.mk("mnt/under", bytes: 100_000)
                let root = FirmlinkTable.system.dataRoot + f.root
                try #require(FirmlinkTable.system.dataVolumePath(f.root) == root)
                try Snapshot.save(try Scanner.scan(root), in: dir)

                guard image.attach(at: f.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
                let mounted = try #require(Snapshot.load(rootPath: root, privateSize: false, in: dir).tree)
                guard case .success(let report) = Incremental.update(mounted) else {
                    Issue.record("update after mount failed")
                    return
                }
                let full = try Scanner.scan(root)
                #expect(report.mountChanges == 1)
                #expect(Totals(mounted) == Totals(full), "mounted: incremental \(Totals(mounted)) full \(Totals(full))")
                #expect(full.root.totalAlloc == f.duBytes())
                #expect(mounted.mountPoints == [MountPoint(parent: 0, name: "mnt")])
                try Snapshot.save(mounted, in: dir)

                // Still mounted: the record matches, nothing is re-read.
                let again = try #require(Snapshot.load(rootPath: root, privateSize: false, in: dir).tree)
                guard case .success(let idle) = Incremental.update(again) else {
                    Issue.record("second update failed")
                    return
                }
                #expect(idle.mountChanges == 0, "\(idle)")

                image.detach()
                guard case .success(let after) = Incremental.update(again) else {
                    Issue.record("update after unmount failed")
                    return
                }
                #expect(after.mountChanges == 1)
                #expect(Totals(again) == Totals(try Scanner.scan(root)))
            } }
        }
    }

    @Test("a recorded mount point the mount table names otherwise is not taken for unmounted",
          .enabled(if: DiskImage.isAvailable, "hdiutil is not available"),
          .enabled(if: !FirmlinkTable.system.dataRoot.isEmpty, "no data volume"))
    func mountNamedOtherwise() throws {
        try withSnapshotDir { dir in
            try Fixture.with("mount") { f in try withImage { image in
                try f.mk("mnt/under", bytes: 100_000)
                try f.mk("keep", bytes: 20_000)
                guard image.attach(at: f.path("mnt")) else { try Test.cancel("hdiutil attach failed") }
                // Without the firmlink table the data-volume root cannot match the table's firmlink name: the
                // recorded mount point is checked on disk instead (as after a rename the table has not followed).
                let options = ScanOptions(firmlinks: .empty)
                let root = FirmlinkTable.system.dataRoot + f.root
                let full = try Scanner.scan(root, options: options)
                #expect(full.mountPoints == [MountPoint(parent: 0, name: "mnt")])
                try Snapshot.save(full, in: dir)
                let tree = try #require(Snapshot.load(rootPath: root, options: options, in: dir).tree)
                guard case .success(let report) = Incremental.update(tree, options: options) else {
                    Issue.record("update failed")
                    return
                }
                #expect(report.mountChanges == 0, "\(report)")
                #expect(tree.mountPoints == [MountPoint(parent: 0, name: "mnt")])
                #expect(Totals(tree) == Totals(full))
            } }
        }
    }

    /// Runs `body` with an APFS image holding a file at its root and one in a folder. The image lives in a fixture of
    /// its own, outside the scanned root: attaching and detaching write to the image file, and that write would give
    /// the root an event of its own. Detached afterwards, also when `body` throws.
    private func withImage(_ body: (DiskImage) throws -> Void) throws {
        try Fixture.with("image") { box in
            try box.mk("src/rootfile", bytes: 400_000)
            try box.mk("src/sub/inner", bytes: 2_000_000)
            guard let image = DiskImage(from: box.path("src"), at: box.path("vol.dmg")) else {
                try Test.cancel("hdiutil create failed")
            }
            defer { image.detach() }
            try body(image)
        }
    }

    @Test("a snapshot of another root is not used")
    func otherRoot() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 10)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                #expect(Snapshot.load(rootPath: f.root + "/a", privateSize: false, in: dir).tree == nil)
            }
        }
    }
}
