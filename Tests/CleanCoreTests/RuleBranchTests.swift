@testable import CleanCore
import Foundation
import ScanCore
import Testing
import TestSupport

@Suite("app-caches and project manifests")
struct RuleBranchTests {
    /// Runs one rule against a fixture home with a chosen set of running bundle ids (no real app list).
    func candidates(_ ruleId: String, in f: Fixture, running: Set<String> = []) async throws -> [Candidate] {
        let tree = try Scanner.scan(f.root, options: ScanOptions(strictHardlinks: false))
        let ctx = RuleContext(home: f.root, tree: tree, runningBundleIds: running, isRealHome: false,
                              tools: Cleanup.startToolQueries(home: f.root))
        let rule = try #require(Rules.all.first { $0.id == ruleId })
        return await rule.candidates(ctx)
    }

    func byName(_ list: [Candidate]) -> [String: Candidate] {
        Dictionary(uniqueKeysWithValues: list.map { (($0.path as NSString).lastPathComponent, $0) })
    }

    @Test("app-caches: a running app's cache is review with the 'app is running' note; a stopped app's stays safe")
    func runningApp() async throws {
        try await Fixture.withAsync("home") { f in
            try f.mk("Library/Caches/com.example.running/f", bytes: 3_000_000)
            try f.mk("Library/Caches/com.example.stopped/f", bytes: 3_000_000)
            try f.mk("Library/Caches/com.apple.bird/f", bytes: 3_000_000)

            let idle = byName(try await candidates("app-caches", in: f))
            #expect(idle["com.example.running"]?.safety == .safe)

            let busy = byName(try await candidates("app-caches", in: f, running: ["com.example.running"]))
            let running = try #require(busy["com.example.running"])
            #expect(running.safety == .review)
            #expect(running.note == .appRunning)
            #expect(running.note?.description == "app is running")
            #expect(busy["com.example.stopped"]?.safety == .safe)
            #expect(busy["com.example.stopped"]?.note == nil)
            #expect(busy["com.apple.bird"]?.safety == .review)
            #expect(busy["com.apple.bird"]?.note == .macOSComponent)
        }
    }

    @Test("a running Apple component keeps the running note, not the Apple one")
    func runningAppleComponent() async throws {
        try await Fixture.withAsync("home") { f in
            try f.mk("Library/Caches/com.apple.bird/f", bytes: 3_000_000)
            let list = try await candidates("app-caches", in: f, running: ["com.apple.bird"])
            #expect(list.first?.note == .appRunning)
        }
    }

    @Test("Pods, .build and .venv count only next to or with their manifest; others are left alone")
    func manifests() async throws {
        try await Fixture.withAsync("home") { f in
            try f.mk("ios/Podfile", bytes: 10)
            try f.mk("ios/Pods/f", bytes: 3_000_000)
            try f.mk("pkg/Package.swift", bytes: 10)
            try f.mk("pkg/.build/f", bytes: 3_000_000)
            try f.mk("py/.venv/pyvenv.cfg", bytes: 10)
            try f.mk("py/.venv/lib/f", bytes: 3_000_000)
            try f.mk("py/venv/pyvenv.cfg", bytes: 10)
            try f.mk("py/venv/lib/f", bytes: 3_000_000)
            // No manifest: not a project's output.
            try f.mk("noios/Pods/f", bytes: 3_000_000)
            try f.mk("nopkg/.build/f", bytes: 3_000_000)
            try f.mk("novenv/.venv/lib/f", bytes: 3_000_000)
            try f.mk("novenv/venv/lib/f", bytes: 3_000_000)

            let list = try await candidates("project-artifacts", in: f)
            #expect(list.map(\.id).sorted() == [
                "project-artifacts:ios/Pods", "project-artifacts:pkg/.build",
                "project-artifacts:py/.venv", "project-artifacts:py/venv",
            ])
            #expect(list.allSatisfy { $0.safety == .review })
            let pods = try #require(list.first { $0.id.hasSuffix("ios/Pods") })
            #expect(pods.note?.description == "Pods, manifest untouched 0 days")
        }
    }
}
