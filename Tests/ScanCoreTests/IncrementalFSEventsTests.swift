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
    /// Hard-link scenarios compare the root only (see `Totals.sameRoot`).
    var rootOnly: Bool { name.hasPrefix("hardlink") }

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
]

enum UpdateOutcome { case incremental(DiskTree, UpdateReport), fellBack(UpdateFailure) }

/// Saves a snapshot of `f`, applies `change`, loads the snapshot and replays the history, like `fil scan` does.
func scanChangeUpdate(_ f: Fixture, dir: URL, options: ScanOptions,
                      change: () throws -> Void) throws -> (outcome: UpdateOutcome, full: DiskTree) {
    let baseline = try Scanner.scan(f.root, options: options)
    try Snapshot.save(baseline, in: dir)
    try change()
    let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: options.privateSize, in: dir))
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
                let loaded = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                guard case .success(let report) = Incremental.update(loaded) else {
                    Issue.record("update failed")
                    return
                }
                // Not asserted: `report.events` may count the fixture's own creation, which fseventsd numbers late.
                #expect(loaded.eventId >= baseline.eventId)
                #expect(Snapshot.advance(loaded, in: dir))
                let again = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
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
                var tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
                for round in 1...3 {
                    try f.mk("a/r\(round)", bytes: 10_000 * round)
                    try f.mk("n\(round)/deep/x", bytes: 777)
                    guard case .success = Incremental.update(tree) else {
                        Issue.record("round \(round): update failed")
                        return
                    }
                    #expect(Totals(tree) == Totals(try Scanner.scan(f.root)), "round \(round)")
                    try Snapshot.save(tree, in: dir)
                    tree = try #require(Snapshot.load(rootPath: f.root, privateSize: false, in: dir))
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

    @Test("a snapshot of another root is not used")
    func otherRoot() throws {
        try withSnapshotDir { dir in
            try Fixture.with { f in
                try f.mk("a/b", bytes: 10)
                try Snapshot.save(try Scanner.scan(f.root), in: dir)
                #expect(Snapshot.load(rootPath: f.root + "/a", privateSize: false, in: dir) == nil)
            }
        }
    }
}
