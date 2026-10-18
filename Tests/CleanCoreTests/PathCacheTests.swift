@testable import CleanCore
import Foundation
import Testing
import TestSupport

@Suite("Dry run and tool-paths.json")
struct PathCacheTests {
    @Test("a read-only path cache is read but never written")
    func readOnlyCache() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("custom/homebrew/f", bytes: 2_000_000)
            let file = URL(fileURLWithPath: f.path("state/tool-paths.json"))
            var cache = ToolPathCache(file: file)
            let answers: [String: CommandResult] = ["/fake/bin/brew --cache": .success(f.path("custom/homebrew") + "\n")]
            let (env1, _) = fakeEnvironment(f, tools: ["brew"], answers: answers, cache: cache)
            _ = await CacheTools.discover(env1)
            // Read-only: a cached answer is used (no command) ...
            cache.readOnly = true
            let (env2, runner2) = fakeEnvironment(f, tools: ["brew"], answers: [:], cache: cache)
            _ = await CacheTools.discover(env2)
            #expect(runner2.calls.isEmpty)
            // ... and a changed answer is not written back.
            var stale = cache.load()
            stale["brew"]?.savedAt -= 8 * 86_400
            var writer = cache
            writer.readOnly = false
            writer.save(stale)
            let before = try Data(contentsOf: file)
            let (env3, runner3) = fakeEnvironment(f, tools: ["brew"], answers: answers, cache: cache)
            _ = await CacheTools.discover(env3)
            #expect(runner3.calls == ["/fake/bin/brew --cache"])
            let after = try Data(contentsOf: file)
            #expect(after == before)
        }
    }
}
