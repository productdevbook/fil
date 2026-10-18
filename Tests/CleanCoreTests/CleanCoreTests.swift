import CleanCore
import Foundation
import ScanCore
import Testing
import TestSupport

// Port of scripts/verify-clean.sh. Trash moves go through a `Trasher`, so these tests never touch ~/.Trash:
// `FakeTrasher` moves the item into a folder inside the test's own temporary directory.

/// Stands in for the Trash: moves the item into `trashDir` and reports where it went.
final class FakeTrasher: Trasher, @unchecked Sendable {
    let trashDir: String
    private let lock = NSLock()
    private var moved: [URL] = []
    var failWith: Error?

    init(trashDir: String) { self.trashDir = trashDir }

    var movedItems: [URL] { lock.withLock { moved } }

    func trash(_ url: URL) throws -> URL? {
        if let failWith { throw failWith }
        let target = URL(fileURLWithPath: trashDir).appendingPathComponent(
            UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        lock.withLock { moved.append(target) }
        return target
    }
}

struct TrashError: Error, LocalizedError {
    var errorDescription: String? { "pretend the Trash is full" }
}

let derivedId = "xcode-derived:Library/Developer/Xcode/DerivedData/a"
let archiveId = "xcode-archives:Library/Developer/Xcode/Archives/x.xcarchive"

/// The fixture of verify-clean.sh: a fake home with every kind of candidate, and things that must be skipped.
func makeHome(_ f: Fixture, outside: Fixture) throws {
    try f.mk("Library/Developer/Xcode/DerivedData/a/f", bytes: 5_000_000)
    try f.mk("Library/Developer/Xcode/Archives/x.xcarchive/f", bytes: 2_000_000)
    try f.mk("Library/Caches/com.example.app/f", bytes: 3_000_000)
    try f.mk("Library/Caches/com.apple.bird/f", bytes: 2_000_000)
    try f.mk("Library/Caches/Homebrew/f", bytes: 2_000_000)
    try f.mk("Library/Logs/foo/f", bytes: 2_000_000)
    try f.mk("proj/package.json", bytes: 20)
    try f.mk("proj/node_modules/f", bytes: 4_000_000)
    try f.mk("proj/node_modules/pkg/node_modules/inner/f", bytes: 1000)
    try f.mk("rust/Cargo.toml", bytes: 20)
    try f.mk("rust/target/f", bytes: 2_000_000)
    try f.mk("Library/Caches/tiny/f", bytes: 500_000)
    try outside.mk("f", bytes: 3_000_000)
    try f.symlink(outside.root, at: "Library/Caches/link")
}

func scanCandidates(_ f: Fixture) async throws -> Cleanup.Scan {
    let tree = try Scanner.scan(f.root, options: ScanOptions(strictHardlinks: false))
    return await Cleanup.scan(home: f.root, tree: tree, tools: Cleanup.startToolQueries(home: f.root))
}

let expected: [String: (rule: String, safety: Safety)] = [
    derivedId: ("xcode-derived", .safe),
    archiveId: ("xcode-archives", .careful),
    "app-caches:Library/Caches/com.example.app": ("app-caches", .safe),
    "app-caches:Library/Caches/com.apple.bird": ("app-caches", .review),
    "homebrew-cache:Library/Caches/Homebrew": ("homebrew-cache", .safe),
    "logs:Library/Logs/foo": ("logs", .safe),
    "project-artifacts:proj/node_modules": ("project-artifacts", .review),
    "project-artifacts:rust/target": ("project-artifacts", .review),
]

@Suite("Cleanup candidates")
struct CandidateTests {
    @Test("the candidate set is exactly the expected eight: no tiny, no symlink target, no nested")
    func candidateSet() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        defer { f.remove(); outside.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        #expect(Set(scan.candidates.map(\.id)) == Set(expected.keys))
        #expect(!scan.candidates.contains { $0.id.contains("Caches/tiny") || $0.id.contains("Caches/link") })
        #expect(!scan.candidates.contains { $0.path.components(separatedBy: "node_modules").count > 2 })
    }

    @Test("rule, safety and removal per candidate; the list is sorted largest first")
    func rulesAndSafety() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        defer { f.remove(); outside.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        for c in scan.candidates {
            let want = try #require(expected[c.id], "unexpected \(c.id)")
            #expect(c.ruleId == want.rule, "\(c.id)")
            #expect(c.safety == want.safety, "\(c.id)")
            guard case .trash = c.removal else { Issue.record("\(c.id) is not removed by the Trash"); continue }
        }
        #expect(scan.candidates.map(\.bytes) == scan.candidates.map(\.bytes).sorted(by: >))
        let bird = try #require(scan.candidates.first { $0.id.hasSuffix("com.apple.bird") })
        #expect(bird.note == .macOSComponent)
        let nm = try #require(scan.candidates.first { $0.id == "project-artifacts:proj/node_modules" })
        guard case .projectArtifact(let kind, _)? = nm.note else { Issue.record("no project note"); return }
        #expect(kind == "node_modules")
    }

    @Test("bytes equal du -sk x 1024 for each candidate")
    func bytesMatchDu() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        defer { f.remove(); outside.remove() }
        try makeHome(f, outside: outside)
        for c in try await scanCandidates(f).candidates {
            let rel = String(c.path.dropFirst(f.root.count + 1))
            #expect(c.bytes == f.duBytes(rel), "\(c.id)")
        }
    }

    @Test("a fixture is not the real home: external commands are skipped")
    func notTheRealHome() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        defer { f.remove(); outside.remove() }
        try makeHome(f, outside: outside)
        #expect(!Cleanup.isRealHome(f.root))
        #expect(Cleanup.isRealHome(NSHomeDirectory()))
        let scan = try await scanCandidates(f)
        #expect(!scan.skippedCommands.isEmpty)
        #expect(!scan.candidates.contains { if case .command = $0.removal { true } else { false } })
    }

    @Test("an empty home has no candidates")
    func emptyHome() async throws {
        try await Fixture.withAsync { f in
            try f.mk("Documents/a.txt", bytes: 10)
            #expect(try await scanCandidates(f).candidates.isEmpty)
        }
    }
}

@Suite("Selectors")
struct ResolveTests {
    func candidates() async throws -> (Fixture, Fixture, [Candidate]) {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        try makeHome(f, outside: outside)
        return (f, outside, try await scanCandidates(f).candidates)
    }

    @Test("a rule id selects its safe and review items and leaves the careful ones out")
    func ruleIdSkipsCareful() async throws {
        let (f, o, all) = try await candidates()
        defer { f.remove(); o.remove() }
        let r = try Cleanup.resolve(["xcode-archives"], in: all)
        #expect(r.chosen.isEmpty)
        #expect(r.leftOut.map(\.id) == [archiveId])
        let r2 = try Cleanup.resolve(["project-artifacts"], in: all)
        #expect(Set(r2.chosen.map(\.id)) == ["project-artifacts:proj/node_modules", "project-artifacts:rust/target"])
        #expect(r2.leftOut.isEmpty)
    }

    @Test("a candidate id selects exactly that candidate, careful included")
    func candidateIdSelectsCareful() async throws {
        let (f, o, all) = try await candidates()
        defer { f.remove(); o.remove() }
        let r = try Cleanup.resolve([archiveId], in: all)
        #expect(r.chosen.map(\.id) == [archiveId])
        #expect(r.leftOut.isEmpty)
    }

    @Test("an id that matches nothing throws; selectors are deduplicated")
    func badAndDuplicateIds() async throws {
        let (f, o, all) = try await candidates()
        defer { f.remove(); o.remove() }
        #expect(throws: Cleanup.NoMatch(selector: "no-such-rule:Library/Nothing")) {
            try Cleanup.resolve(["no-such-rule:Library/Nothing"], in: all)
        }
        #expect(throws: Cleanup.NoMatch.self) { try Cleanup.resolve([derivedId, "typo"], in: all) }
        let r = try Cleanup.resolve([derivedId, "xcode-derived", derivedId], in: all)
        #expect(r.chosen.map(\.id) == [derivedId])
    }
}

@Suite("Cleanup.execute with a fake Trash")
struct ExecuteTests {
    @Test("a dry run (resolve only) changes nothing on disk")
    func dryRunChangesNothing() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        defer { f.remove(); outside.remove() }
        try makeHome(f, outside: outside)
        let before = f.listing()
        let scan = try await scanCandidates(f)
        _ = try Cleanup.resolve(["xcode-archives", "logs"], in: scan.candidates)
        #expect(f.listing() == before)
    }

    @Test("cleaning by rule id keeps the careful archive")
    func carefulKeptByRuleId() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let r = try Cleanup.resolve(["xcode-archives"], in: scan.candidates)
        let results = await Cleanup.execute(r.chosen, home: scan.home, trasher: FakeTrasher(trashDir: trash.path("t")))
        #expect(results.isEmpty)
        #expect(f.exists("Library/Developer/Xcode/Archives/x.xcarchive"))
    }

    @Test("xcode-derived moves DerivedData/a to the Trash and the next scan no longer lists it")
    func derivedMoved() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let fake = FakeTrasher(trashDir: trash.path("t"))
        let scan = try await scanCandidates(f)
        let r = try Cleanup.resolve(["xcode-derived"], in: scan.candidates)
        let results = await Cleanup.execute(r.chosen, home: scan.home, trasher: fake)
        #expect(results.count == 1)
        guard case .trashed(let url) = results[0].1 else { Issue.record("not trashed: \(results[0].1)"); return }
        #expect(fake.movedItems == [url])
        #expect(FileManager.default.fileExists(atPath: url.path + "/f"))
        #expect(!f.exists("Library/Developer/Xcode/DerivedData/a"))
        // Everything else is untouched.
        #expect(f.exists("Library/Caches/com.example.app/f"))
        #expect(f.exists("Library/Developer/Xcode/Archives/x.xcarchive/f"))
        let after = try await scanCandidates(f)
        #expect(!after.candidates.contains { $0.id == derivedId })
        #expect(after.candidates.count == scan.candidates.count - 1)
    }

    @Test("a careful archive named by its candidate id moves to the Trash")
    func carefulById() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let r = try Cleanup.resolve([archiveId], in: scan.candidates)
        let results = await Cleanup.execute(r.chosen, home: scan.home, trasher: FakeTrasher(trashDir: trash.path("t")))
        guard case .trashed? = results.first?.1 else { Issue.record("not trashed: \(results)"); return }
        #expect(!f.exists("Library/Developer/Xcode/Archives/x.xcarchive"))
    }

    @Test("one failure does not stop the others, and the failure carries the reason")
    func failureIsolated() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let fake = FakeTrasher(trashDir: trash.path("t"))
        fake.failWith = TrashError()
        let r = try Cleanup.resolve(["logs", "xcode-derived"], in: scan.candidates)
        let results = await Cleanup.execute(r.chosen, home: scan.home, trasher: fake)
        #expect(results.count == 2)
        for (_, outcome) in results {
            guard case .failed(.system(let why)) = outcome else {
                Issue.record("expected a failure: \(outcome)"); continue
            }
            #expect(why.contains("Trash is full"))
        }
        #expect(f.exists("Library/Logs/foo/f"))
    }

    @Test("an item that changed since the scan is skipped, never moved")
    func pathChanged() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let logs = try #require(scan.candidates.first { $0.id == "logs:Library/Logs/foo" })
        let derived = try #require(scan.candidates.first { $0.id == derivedId })
        // 1. replaced by a symlink to a folder outside the home  2. gone  3. never inside the home
        try f.remove("Library/Logs/foo")
        try f.symlink(outside.root, at: "Library/Logs/foo")
        try f.remove("Library/Developer/Xcode/DerivedData/a")
        let elsewhere = Candidate(id: "x", ruleId: "logs", path: outside.root, bytes: 1, safety: .safe)
        let fake = FakeTrasher(trashDir: trash.path("t"))
        let results = await Cleanup.execute([logs, derived, elsewhere], home: scan.home, trasher: fake)
        for (c, outcome) in results {
            guard case .failed(.pathChanged) = outcome else { Issue.record("\(c.id): \(outcome)"); continue }
        }
        #expect(fake.movedItems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.root + "/f"))
    }

    /// A trasher that moves a different folder than the one it was asked for, as a swapped path would.
    final class WrongItemTrasher: Trasher, @unchecked Sendable {
        let other: String, trashDir: String
        init(other: String, trashDir: String) { self.other = other; self.trashDir = trashDir }
        func trash(_ url: URL) throws -> URL? {
            try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: trashDir).appendingPathComponent("wrong")
            try FileManager.default.moveItem(atPath: other, toPath: target.path)
            return target
        }
    }

    @Test("a symlinked ancestor, a replaced item and another device are skipped; nothing moves")
    func identityRecheck() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let logs = try #require(scan.candidates.first { $0.id == "logs:Library/Logs/foo" })
        let derived = try #require(scan.candidates.first { $0.id == derivedId })
        let cache = try #require(scan.candidates.first { $0.id == "app-caches:Library/Caches/com.example.app" })
        let apple = try #require(scan.candidates.first { $0.id == "app-caches:Library/Caches/com.apple.bird" })
        // 1. Library/Logs becomes a symlink to a folder that also has a "foo" (same device, last component is a dir)
        try outside.mk("L/foo/f", bytes: 10)
        try f.move("Library/Logs", to: "Library/Logs.orig")
        try f.symlink(outside.path("L"), at: "Library/Logs")
        // 2. the item is replaced by a new folder of the same name (the old one is kept, so the inode is new)
        try f.move("Library/Developer/Xcode/DerivedData/a", to: "Library/Developer/Xcode/DerivedData/a.old")
        try f.mk("Library/Developer/Xcode/DerivedData/a/f", bytes: 10)
        // 3. the recorded device is not the home volume's
        let otherDev = Candidate(
            id: cache.id, ruleId: cache.ruleId, path: cache.path, bytes: cache.bytes,
            safety: cache.safety, fileID: FileID(dev: cache.fileID!.dev &+ 1, ino: cache.fileID!.ino))
        // 4. no identity recorded; and a path that climbs out with ".."
        let noID = Candidate(
            id: apple.id, ruleId: apple.ruleId, path: apple.path, bytes: apple.bytes, safety: apple.safety)
        let dots = Candidate(
            id: "d", ruleId: "r", path: f.root + "/Library/Caches/../Logs.orig/foo", bytes: 1,
            safety: .safe, fileID: logs.fileID)
        let fake = FakeTrasher(trashDir: trash.path("t"))
        let results = await Cleanup.execute([logs, derived, otherDev, noID, dots], home: scan.home, trasher: fake)
        for (c, outcome) in results {
            guard case .failed(.pathChanged) = outcome else { Issue.record("\(c.id): \(outcome)"); continue }
        }
        #expect(results.count == 5)
        #expect(fake.movedItems.isEmpty)
        #expect(outside.exists("L/foo/f"))
        #expect(f.exists("Library/Caches/com.example.app/f"))
    }

    @Test("a different item in the Trash after the move is reported with where it is")
    func movedOtherItem() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let logs = try #require(scan.candidates.first { $0.id == "logs:Library/Logs/foo" })
        let t = WrongItemTrasher(other: f.path("Library/Caches/com.example.app"), trashDir: trash.path("t"))
        let results = await Cleanup.execute([logs], home: scan.home, trasher: t)
        guard case .failed(.movedOtherItem(let url))? = results.first?.1 else { Issue.record("\(results)"); return }
        #expect(url.path == trash.path("t/wrong"))
        #expect(
            Cleanup.Failure.movedOtherItem(url).description
                == "a different item was moved to the Trash at \(url.path); put it back")
    }

    @Test("a move whose destination the system does not report is not called a mix-up")
    func movedUnverified() async throws {
        final class SilentTrasher: Trasher, @unchecked Sendable {
            func trash(_ url: URL) throws -> URL? { nil }
        }
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside")
        defer { f.remove(); outside.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let logs = try #require(scan.candidates.first { $0.id == "logs:Library/Logs/foo" })
        let results = await Cleanup.execute([logs], home: scan.home, trasher: SilentTrasher())
        guard case .failed(.movedUnverified)? = results.first?.1 else { Issue.record("\(results)"); return }
        #expect(
            Cleanup.Failure.movedUnverified.description
                == "moved to the Trash, but the system did not say where; check the Trash")
    }

    @Test("info-only items do nothing; a command runs once for candidates that share it")
    func commandsAndInfoOnly() async throws {
        try await Fixture.withAsync { f in
            let info = Candidate(
                id: "trash:.Trash", ruleId: "trash", path: f.path(".Trash"), bytes: 1, safety: .review,
                removal: .none)
            let a = Candidate(
                id: "a", ruleId: "r", path: f.path("a"), bytes: 1, safety: .safe,
                removal: .command(argv: ["/usr/bin/true"]))
            let b = Candidate(
                id: "b", ruleId: "r", path: f.path("b"), bytes: 1, safety: .safe,
                removal: .command(argv: ["/usr/bin/true"]))
            let bad = Candidate(
                id: "c", ruleId: "r", path: f.path("c"), bytes: 1, safety: .safe,
                removal: .command(argv: ["/usr/bin/false"]))
            let bad2 = Candidate(
                id: "d", ruleId: "r", path: f.path("d"), bytes: 1, safety: .safe,
                removal: .command(argv: ["/usr/bin/false"]))
            let results = await Cleanup.execute(
                [info, a, b, bad, bad2], home: f.root,
                trasher: FakeTrasher(trashDir: f.path("t")))
            func kind(_ o: Cleanup.Outcome) -> String {
                switch o {
                case .nothingToDo: "nothing"
                case .commandRan: "ran"
                case .commandShared: "shared"
                case .failed: "failed"
                case .trashed: "trashed"
                }
            }
            #expect(results.map { kind($0.1) } == ["nothing", "ran", "shared", "failed", "failed"])
        }
    }
}

@Suite("The real Trash (opt-in)")
struct RealTrashTests {
    /// Moves a real folder to the user's ~/.Trash, so it is off by default and never runs on CI.
    /// Enable with `FIL_REAL_TRASH_TESTS=1 swift test --filter RealTrashTests`. The test removes exactly the
    /// Trash item it created. Reading ~/.Trash needs Full Disk Access for the terminal running the tests.
    static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["FIL_REAL_TRASH_TESTS"] == "1" && env["CI"] == nil && env["GITHUB_ACTIONS"] == nil
    }()

    @Test("SystemTrasher moves a folder into ~/.Trash and reports where", .enabled(if: RealTrashTests.enabled))
    func systemTrasher() throws {
        try Fixture.with { f in
            try f.mk("item/f", bytes: 1000)
            let url = try #require(try SystemTrasher().trash(URL(fileURLWithPath: f.path("item"))))
            let trash = NSHomeDirectory() + "/.Trash/"
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(url.path.hasPrefix(trash))
            #expect(FileManager.default.fileExists(atPath: url.path + "/f"))
            #expect(!f.exists("item"))
        }
    }
}
