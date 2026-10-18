import CleanCore
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
            try await Task.sleep(for: .milliseconds(500))
            let alive = try running("sleep 29.9792"); #expect(alive)
            work.cancel()
            let results = await work.value
            #expect(results.count == 1)
            guard case .failed = results[0].1 else { Issue.record("expected a failure"); return }
            let stillAlive = try running("sleep 29.9792"); #expect(stillAlive == false, "the command is still running after cancel")
        }
    }
}
