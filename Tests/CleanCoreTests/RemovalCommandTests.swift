@testable import CleanCore
import Foundation
import Testing
import TestSupport

// Removal commands run through the CommandRunner with a timeout (chapter 04 §7.3, #14). The "hanging tool" is
// /bin/sleep with an odd duration; the timeout is injected so the tests take about a second.

private func command(_ id: String, _ argv: [String], home: String) -> Candidate {
    Candidate(id: id, ruleId: "r", path: home + "/" + id, bytes: 1, safety: .safe, removal: .command(argv: argv))
}

private func running(_ pattern: String) throws -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", pattern]
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// Waits (up to 5 s) until a process matching `pattern` exists.
private func waitUntilRunning(_ pattern: String) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try running(pattern) { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return false
}

/// A Trasher that cancels the task it runs in right after the `after`-th move (Ctrl-C between two items).
final class CancellingTrasher: Trasher, @unchecked Sendable {
    let inner: FakeTrasher
    let after: Int
    private let lock = NSLock()
    private var count = 0
    init(inner: FakeTrasher, after: Int) { self.inner = inner; self.after = after }

    func trash(_ url: URL) throws -> URL? {
        let r = try inner.trash(url)
        let n = lock.withLock { count += 1; return count }
        if n == after { withUnsafeCurrentTask { $0?.cancel() } }
        return r
    }
}

@Suite("Removal commands")
struct RemovalCommandTests {
    @Test("a hanging removal command fails as timedOut, is killed, and the next item still runs")
    func hangingCommandTimesOut() async throws {
        try await Fixture.withAsync { f in
            let hang = command("hang", ["/bin/sleep", "27.1828"], home: f.root)
            let next = command("next", ["/usr/bin/true"], home: f.root)
            let clock = ContinuousClock()
            let start = clock.now
            let results = await Cleanup.execute([hang, next], home: f.root, removalTimeout: .seconds(1))
            #expect(clock.now - start < .seconds(8))
            guard case .failed(let why) = results[0].1 else { Issue.record("expected a failure"); return }
            #expect(why == .timedOut(seconds: 1))
            #expect(why.description == "timed out after 1 s; the command was stopped")
            guard case .commandRan = results[1].1 else { Issue.record("the next item did not run"); return }
            let alive = try running("sleep 27.1828"); #expect(alive == false, "the hung process is still running")
        }
    }

    @Test("a failed removal command reports the tool name and the reason")
    func failureMessage() async throws {
        try await Fixture.withAsync { f in
            let results = await Cleanup.execute([command("bad", ["/usr/bin/false"], home: f.root)], home: f.root)
            guard case .failed(.system(let text)) = results[0].1 else { Issue.record("expected a failure"); return }
            #expect(text.hasPrefix("false failed:"))
        }
    }

    @Test("removal commands go through the injected runner with the removal timeout")
    func usesRunner() async throws {
        try await Fixture.withAsync { f in
            let runner = FakeRunner(["/fake/tool prune": .success("")])
            let results = await Cleanup.execute([command("a", ["/fake/tool", "prune"], home: f.root)], home: f.root,
                                                runner: runner, removalTimeout: .seconds(7))
            guard case .commandRan = results[0].1 else { Issue.record("expected commandRan"); return }
            #expect(runner.calls == ["/fake/tool prune"])
        }
    }

    @Test("cancelling the task stops the running command and the later items")
    func cancellationStopsCommand() async throws {
        try await Fixture.withAsync { f in
            let hang = command("hang", ["/bin/sleep", "29.9792"], home: f.root)
            let next = command("next", ["/usr/bin/true"], home: f.root)
            let home = f.root
            let work = Task { await Cleanup.execute([hang, next], home: home) }
            let started = try await waitUntilRunning("sleep 29.9792")
            #expect(started)
            work.cancel()
            let results = await work.value
            #expect(results.count == 1)
            guard case .failed = results[0].1 else { Issue.record("expected a failure"); return }
            let stillAlive = try running("sleep 29.9792"); #expect(stillAlive == false, "the command is still running after cancel")
        }
    }

    @Test("a helper that ignores SIGTERM does not survive the stop")
    func helperIgnoringTermIsKilled() async throws {
        // The leader dies on SIGTERM; the helper keeps running (and keeps the pipes open) unless the group is killed.
        let script = "(trap '' TERM; exec /bin/sleep 23.1415) & wait"
        let runner = SystemCommandRunner(gracePeriod: .seconds(1))
        let r = await runner.run(["/bin/sh", "-c", script], timeout: .milliseconds(400))
        #expect(r == .timedOut)
        try await Task.sleep(for: .milliseconds(200))
        let alive = try running("sleep 23.1415")
        #expect(alive == false, "the helper survived")
    }

    @Test("Ctrl-C between trash items: nothing after the cancelled item is moved")
    func cancelStopsTrashItems() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let items = scan.candidates.filter { if case .trash = $0.removal { return $0.safety != .careful } else { return false } }
        #expect(items.count >= 3)
        let three = Array(items.prefix(3))
        let trasher = CancellingTrasher(inner: FakeTrasher(trashDir: trash.path("t")), after: 1)
        let home = scan.home
        let work = Task { await Cleanup.executeReporting(three, home: home, trasher: trasher) }
        let (results, stopped) = await work.value
        #expect(results.count == 1)
        #expect(stopped)
        #expect(trasher.inner.movedItems.count == 1)
        for c in three.dropFirst() { #expect(FileManager.default.fileExists(atPath: c.path), "\(c.id) was moved") }
    }

    @Test("a cancellation after the last item is not 'stopped early'")
    func cancelAfterLastItem() async throws {
        let f = try Fixture(label: "home"), outside = try Fixture(label: "outside"), trash = try Fixture(label: "trash")
        defer { f.remove(); outside.remove(); trash.remove() }
        try makeHome(f, outside: outside)
        let scan = try await scanCandidates(f)
        let one = Array(scan.candidates.filter { if case .trash = $0.removal { return $0.safety != .careful } else { return false } }.prefix(1))
        let trasher = CancellingTrasher(inner: FakeTrasher(trashDir: trash.path("t")), after: 1)
        let home = scan.home
        let work = Task { await Cleanup.executeReporting(one, home: home, trasher: trasher) }
        let (results, stopped) = await work.value
        #expect(results.count == 1)
        #expect(!stopped)
    }

    @Test("a tool that traps SIGTERM and exits with its own status is still a timeout")
    func trappedTermTimesOut() async throws {
        for (status, sleepFor) in [(3, "21.111"), (0, "21.222")] {
            let runner = SystemCommandRunner(gracePeriod: .seconds(1))
            let r = await runner.run(["/bin/sh", "-c", "trap 'exit \(status)' TERM; /bin/sleep \(sleepFor)"],
                                     timeout: .milliseconds(400))
            #expect(r == .timedOut, "exit \(status) after TERM")
        }
    }

    @Test("a tool that traps SIGTERM and exits with its own status is still an interruption")
    func trappedTermIsInterrupted() async throws {
        for (status, sleepFor) in [(3, "22.111"), (0, "22.222")] {
            try await Fixture.withAsync { f in
                let item = command("trap", ["/bin/sh", "-c", "trap 'exit \(status)' TERM; /bin/sleep \(sleepFor)"], home: f.root)
                let home = f.root
                let work = Task { await Cleanup.executeReporting([item], home: home) }
                let started = try await waitUntilRunning("sleep \(sleepFor)")
                #expect(started)
                work.cancel()
                let (results, stopped) = await work.value
                #expect(stopped, "exit \(status) after TERM")
                guard case .failed(let why) = results[0].1 else { Issue.record("exit \(status): expected a failure"); return }
                #expect(why == .system("interrupted; the command was stopped"))
            }
        }
    }
}
