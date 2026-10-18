@testable import CleanCore
import Foundation
import ScanCore
import Testing
import TestSupport

// Tool queries run through a fake `CommandRunner`: no test needs brew, npm, simctl or docker, so these run
// headless on CI. Only the timeout tests start real (harmless) processes: /bin/sleep, /bin/echo, /usr/bin/false.

/// Answers by argv (joined with spaces); unknown commands fail. Records every call.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let answers: [String: CommandResult]
    private let lock = NSLock()
    private var log: [String] = []

    init(_ answers: [String: CommandResult]) { self.answers = answers }

    var calls: [String] { lock.withLock { log } }

    func run(_ argv: [String], timeout: Duration) async -> CommandResult {
        let key = argv.joined(separator: " ")
        lock.withLock { log.append(key) }
        return answers[key] ?? .failed("exit 127: not faked")
    }
}

/// Tools in `/fake/bin`, only those named.
func fakeEnvironment(
    _ f: Fixture, tools: Set<String>, answers: [String: CommandResult],
    cache: ToolPathCache? = nil, dockerMayAutostart: Bool = false
) -> (ToolEnvironment, FakeRunner) {
    let runner = FakeRunner(answers)
    let env = ToolEnvironment(
        home: f.root, runner: runner, locate: { tools.contains($0) ? "/fake/bin/\($0)" : nil },
        timeout: .seconds(3), pathCache: cache, dockerMayAutostart: { dockerMayAutostart })
    return (env, runner)
}

func scanWithTools(_ f: Fixture, _ env: ToolEnvironment) async throws -> Cleanup.Scan {
    let tree = try Scanner.scan(f.root, options: ScanOptions(strictHardlinks: false))
    return await Cleanup.scan(home: f.root, tree: tree, tools: Cleanup.startToolQueries(home: f.root, environment: env))
}

@Suite("Tool-reported cache locations")
struct CachePathTests {
    @Test("parse accepts one absolute path per expected line and nothing else")
    func parse() {
        let npm = CacheTools.packageManagers.first { $0.name == "npm" }!
        let go = CacheTools.packageManagers.first { $0.name == "go" }!
        #expect(CacheTools.parse("/Users/x/.npm\n", for: npm) == ["/Users/x/.npm"])
        #expect(CacheTools.parse("  /a/b/../c  \n", for: npm) == ["/a/c"])
        #expect(CacheTools.parse("undefined\n", for: npm) == nil)
        #expect(CacheTools.parse("", for: npm) == nil)
        #expect(CacheTools.parse("/a\n/b\n", for: npm) == nil)
        #expect(
            CacheTools.parse("/u/go/pkg/mod\n/u/Library/Caches/go-build\n", for: go)
                == ["/u/go/pkg/mod", "/u/Library/Caches/go-build"])
        #expect(CacheTools.parse("/u/go/pkg/mod\n", for: go) == nil)
    }

    @Test("reported paths become candidates; missing, failing, timed-out and garbled tools fall back to defaults")
    func discovery() async throws {
        try await Fixture.withAsync("tools") { f in
            let mb = 2_000_000
            try f.mk("custom/homebrew/f", bytes: mb)  // brew --cache
            try f.mk("Library/Caches/Homebrew/f", bytes: mb)  // default, not reported: must not appear
            try f.mk("npmcache/_cacache/f", bytes: mb)  // npm: <reported>/_cacache
            try f.mk("npmcache/_logs/f", bytes: mb)  // npm logs are not the cache
            try f.mk("dev/gomod/f", bytes: mb)
            try f.mk("dev/go-build/f", bytes: mb)
            try f.mk("Library/Caches/pip/f", bytes: mb)  // pip fails -> default
            try f.mk("Library/Caches/Yarn/f", bytes: mb)  // yarn times out -> default
            try f.mk(".cache/uv/f", bytes: mb)  // uv prints garbage -> default
            try f.mk("Library/pnpm/store/f", bytes: mb)  // pnpm missing -> default, silently
            let b = "/fake/bin/"
            let (env, _) = fakeEnvironment(
                f, tools: ["brew", "npm", "go", "pip3", "yarn", "uv"],
                answers: [
                    b + "brew --cache": .success(f.path("custom/homebrew") + "\n"),
                    b + "npm config get cache": .success(f.path("npmcache") + "\n"),
                    b + "go env GOMODCACHE GOCACHE": .success(
                        f.path("dev/gomod") + "\n" + f.path("dev/go-build") + "\n"),
                    b + "pip3 cache dir": .failed("exit 1: boom"),
                    b + "yarn cache dir": .timedOut,
                    b + "uv cache dir": .success("error: no cache\n"),
                ])
            let scan = try await scanWithTools(f, env)
            let ids = Set(scan.candidates.map(\.id))
            #expect(
                ids == [
                    "homebrew-cache:custom/homebrew", "pkg-caches:npmcache/_cacache", "pkg-caches:dev/gomod",
                    "pkg-caches:dev/go-build",
                    "pkg-caches:Library/Caches/pip", "pkg-caches:Library/Caches/Yarn", "pkg-caches:.cache/uv",
                    "pkg-caches:Library/pnpm/store",
                    // The unreported default Homebrew folder is just another app cache now.
                    "app-caches:Library/Caches/Homebrew",
                ])
            for c in scan.candidates {
                let want: Removal =
                    switch c.id {
                    case "pkg-caches:dev/gomod": .command(argv: ["/fake/bin/go", "clean", "-modcache"])
                    case "pkg-caches:dev/go-build": .command(argv: ["/fake/bin/go", "clean", "-cache"])
                    default: .trash
                    }
                #expect(c.removal == want, "\(c.id)")
            }
            // Reported and not the default: careful with a note; defaults stay as they were.
            for c in scan.candidates {
                let custom = [
                    "homebrew-cache:custom/homebrew", "pkg-caches:npmcache/_cacache", "pkg-caches:dev/gomod",
                    "pkg-caches:dev/go-build",
                ].contains(c.id)
                #expect(c.safety == (custom ? .careful : c.ruleId == "pkg-caches" ? .review : .safe), "\(c.id)")
                if custom, let note = c.note, case .customCacheLocation = note {
                } else if custom {
                    Issue.record("\(c.id): note \(String(describing: c.note))")
                }
            }
            for c in scan.candidates { #expect(c.bytes == f.duBytes(String(c.path.dropFirst(f.root.count + 1)))) }
            let notes = scan.skippedCommands.joined(separator: "\n")
            #expect(notes.contains("pip3 cache dir: exit 1: boom"))
            #expect(notes.contains("yarn cache dir: timed out after 3 s"))
            #expect(notes.contains("uv cache dir: unexpected output"))
            #expect(!notes.contains("pnpm"))
        }
    }

    @Test("a reported path outside home yields nothing for that tool")
    func outsideHome() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("Library/Caches/Homebrew/f", bytes: 2_000_000)
            let (env, _) = fakeEnvironment(
                f, tools: ["brew"], answers: ["/fake/bin/brew --cache": .success("/Volumes/X/brew\n")])
            let scan = try await scanWithTools(f, env)
            #expect(!scan.candidates.contains { $0.ruleId == "homebrew-cache" })
        }
    }

    @Test("the Go caches are only reported when go names them, and are removed by go clean")
    func goNeedsGo() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("go/pkg/mod/m/f", bytes: 2_000_000)
            try f.mk("Library/Caches/go-build/f", bytes: 2_000_000)
            for tools: Set<String> in [[], ["go"]] {  // go missing; go failing
                let (env, _) = fakeEnvironment(f, tools: tools, answers: [:])
                let scan = try await scanWithTools(f, env)
                #expect(!scan.candidates.contains { $0.ruleId == "pkg-caches" })
                #expect(!scan.candidates.contains { if case .command = $0.removal { true } else { false } })
                // go-build is an ordinary cache folder then; the read-only module cache is not reported at all.
                #expect(scan.candidates.map(\.id) == ["app-caches:Library/Caches/go-build"])
            }
        }
    }

    @Test(
        "a tool reporting home or a shared folder as its cache yields nothing; a parent of a reported cache is not reported again"
    )
    func sharedLocations() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("Library/Caches/com.example.app/f", bytes: 2_000_000)
            try f.mk("Library/Caches/Yarn/v6/f", bytes: 2_000_000)
            try f.mk("Library/Caches/Yarn/other/f", bytes: 2_000_000)
            let b = "/fake/bin/"
            let (env, _) = fakeEnvironment(
                f, tools: ["brew", "uv", "yarn"],
                answers: [
                    b + "brew --cache": .success(f.path("Library/Caches") + "\n"),
                    b + "uv cache dir": .success(f.root + "\n"),
                    b + "yarn cache dir": .success(f.path("Library/Caches/Yarn/v6") + "\n"),
                ])
            let scan = try await scanWithTools(f, env)
            #expect(
                Set(scan.candidates.map(\.id)) == [
                    "pkg-caches:Library/Caches/Yarn/v6",
                    "app-caches:Library/Caches/com.example.app",
                ])
        }
    }

    @Test("a reported path must be two levels below home and look like a cache; otherwise it is ignored with a note")
    func depthAndMarker() async throws {
        try await Fixture.withAsync("tools") { f in
            let mb = 2_000_000
            try f.mk("Projects/f", bytes: mb)  // PIP_CACHE_DIR=~/Projects
            try f.mk("Developer/f", bytes: mb)  // HOMEBREW_CACHE=~/Developer
            try f.mk("Documents/Taxes/f", bytes: mb)  // deep enough, but no marker
            try f.mk("work/cache/f", bytes: mb)  // generic marker
            try f.mk("x/pip-cache/_cacache/f", bytes: mb)
            try f.mk("tools/uv/f", bytes: mb)  // exact marker
            let b = "/fake/bin/"
            let (env, _) = fakeEnvironment(
                f, tools: ["brew", "pip3", "yarn", "pnpm", "uv", "npm"],
                answers: [
                    b + "pip3 cache dir": .success(f.path("Projects") + "\n"),
                    b + "brew --cache": .success(f.path("Developer") + "\n"),
                    b + "yarn cache dir": .success(f.path("Documents/Taxes") + "\n"),
                    b + "pnpm store path": .success(f.path("work/cache") + "\n"),
                    b + "uv cache dir": .success(f.path("tools/uv") + "\n"),
                    b + "npm config get cache": .success(f.path("x/pip-cache") + "\n"),
                ])
            let scan = try await scanWithTools(f, env)
            let pkg = Set(
                scan.candidates.filter { $0.ruleId == "pkg-caches" || $0.ruleId == "homebrew-cache" }.map(\.id))
            #expect(pkg == ["pkg-caches:work/cache", "pkg-caches:tools/uv", "pkg-caches:x/pip-cache/_cacache"])
            for c in scan.candidates where pkg.contains(c.id) {
                #expect(c.safety == .careful, "\(c.id)")
                guard case .customCacheLocation? = c.note else {
                    Issue.record("\(c.id): \(String(describing: c.note))"); continue
                }
            }
            #expect(
                scan.candidates.first { $0.id == "pkg-caches:work/cache" }?.note?.description
                    == "pnpm keeps its cache in a non-default folder")
            #expect(
                Set(scan.skippedCommands) == [
                    "pip3: reported cache ~/Projects does not look like a cache folder; ignored",
                    "brew: reported cache ~/Developer does not look like a cache folder; ignored",
                    "yarn: reported cache ~/Documents/Taxes does not look like a cache folder; ignored",
                ])
            // The folders themselves are never candidates of the cache rules.
            #expect(!scan.candidates.contains { $0.path.hasSuffix("/Projects") || $0.path.hasSuffix("/Developer") })
        }
    }

    @Test(
        "a custom location is careful: a rule id leaves it out, its own id selects it; versioned defaults stay default")
    func customIsCareful() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("x/pip-cache/f", bytes: 2_000_000)
            try f.mk("Library/Caches/Yarn/v6/f", bytes: 2_000_000)
            let b = "/fake/bin/"
            let (env, _) = fakeEnvironment(
                f, tools: ["pip3", "yarn"],
                answers: [
                    b + "pip3 cache dir": .success(f.path("x/pip-cache") + "\n"),
                    b + "yarn cache dir": .success(f.path("Library/Caches/Yarn/v6") + "\n"),
                ])
            let scan = try await scanWithTools(f, env)
            let r = try Cleanup.resolve(["pkg-caches"], in: scan.candidates)
            #expect(r.chosen.map(\.id) == ["pkg-caches:Library/Caches/Yarn/v6"])
            #expect(r.leftOut.map(\.id) == ["pkg-caches:x/pip-cache"])
            #expect(try Cleanup.resolve(["pkg-caches:x/pip-cache"], in: scan.candidates).chosen.count == 1)
        }
    }

    @Test("Go: if either path is refused, neither is reported; a custom pair is careful commands")
    func goAllOrNothing() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("dev/gomod/f", bytes: 2_000_000)
            try f.mk("Projects/f", bytes: 2_000_000)
            try f.mk("dev/go-build/f", bytes: 2_000_000)
            let q = "/fake/bin/go env GOMODCACHE GOCACHE"
            let (bad, _) = fakeEnvironment(
                f, tools: ["go"],
                answers: [
                    q: .success(f.path("Projects") + "\n" + f.path("dev/go-build") + "\n")
                ])
            let scan = try await scanWithTools(f, bad)
            #expect(!scan.candidates.contains { $0.ruleId == "pkg-caches" })
            #expect(
                scan.skippedCommands == ["go: reported cache ~/Projects does not look like a cache folder; ignored"])
            let (good, _) = fakeEnvironment(
                f, tools: ["go"],
                answers: [
                    q: .success(f.path("dev/gomod") + "\n" + f.path("dev/go-build") + "\n")
                ])
            let ok = try await scanWithTools(f, good)
            #expect(ok.candidates.count == 2)
            for c in ok.candidates { #expect(c.ruleId == "pkg-caches" && c.safety == .careful) }
        }
    }

    @Test("the marker must be in the folder or its parent; GOMODCACHE=~/go/src and marked ancestors are refused")
    func markerPosition() async throws {
        try await Fixture.withAsync("tools") { f in
            let mb = 2_000_000
            try f.mk("go/src/f", bytes: mb)
            try f.mk("cache-backup/Projects/f", bytes: mb)
            try f.mk("Developer/store/f", bytes: mb)
            try f.mk("dev/go-build/f", bytes: mb)
            let b = "/fake/bin/"
            let (env, _) = fakeEnvironment(
                f, tools: ["go", "uv", "pnpm"],
                answers: [
                    b + "go env GOMODCACHE GOCACHE": .success(f.path("go/src") + "\n" + f.path("dev/go-build") + "\n"),
                    b + "uv cache dir": .success(f.path("cache-backup/Projects") + "\n"),
                    b + "pnpm store path": .success(f.path("Developer/store") + "\n"),
                ])
            let scan = try await scanWithTools(f, env)
            #expect(!scan.candidates.contains { $0.ruleId == "pkg-caches" })
            #expect(
                !scan.candidates.contains {
                    if case .command = $0.removal { true } else { false }
                })
            #expect(
                Set(scan.skippedCommands) == [
                    "go: reported cache ~/go/src does not look like a cache folder; ignored",
                    "uv: reported cache ~/cache-backup/Projects does not look like a cache folder; ignored",
                    "pnpm: reported cache ~/Developer/store does not look like a cache folder; ignored",
                ])
        }
    }

    @Test("a default location that is a symlink to a user folder is not trusted; a wrong Go path count reports nothing")
    func symlinkedDefaultAndGoCount() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("Projects/f", bytes: 2_000_000)
            try f.mkdir("Library/Caches")
            try f.symlink(f.path("Projects"), at: "Library/Caches/Homebrew")
            try f.mk("go/pkg/mod/f", bytes: 2_000_000)
            try f.mk("Library/Caches/go-build/f", bytes: 2_000_000)
            let b = "/fake/bin/"
            let (env, _) = fakeEnvironment(
                f, tools: ["brew", "go"],
                answers: [
                    b + "brew --cache": .success(f.path("Projects") + "\n"),
                    b + "go env GOMODCACHE GOCACHE": .success(f.path("go/pkg/mod") + "\n"),  // one line, two expected
                ])
            let scan = try await scanWithTools(f, env)
            #expect(!scan.candidates.contains { $0.ruleId == "homebrew-cache" })
            #expect(!scan.candidates.contains { $0.path.hasSuffix("/Projects") })
            #expect(!scan.candidates.contains { $0.ruleId == "pkg-caches" })
            #expect(
                scan.skippedCommands.contains(
                    "brew: reported cache ~/Projects does not look like a cache folder; ignored"))
        }
    }

    @Test("a symlinked default whose target looks like a cache is careful, not safe")
    func symlinkedDefaultIsCareful() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("Developer/cache-server/f", bytes: 2_000_000)
            try f.mkdir("Library/Caches")
            try f.symlink(f.path("Developer/cache-server"), at: "Library/Caches/Homebrew")
            let (env, _) = fakeEnvironment(
                f, tools: ["brew"],
                answers: [
                    "/fake/bin/brew --cache": .success(f.path("Developer/cache-server") + "\n")
                ])
            let scan = try await scanWithTools(f, env)
            let c = try #require(scan.candidates.first { $0.ruleId == "homebrew-cache" })
            #expect(c.safety == .careful)
            guard case .customCacheLocation(let tool)? = c.note else {
                Issue.record("\(String(describing: c.note))"); return
            }
            #expect(tool == "brew")
        }
    }

    @Test("a damaged tool-paths.json (wrong count, relative paths) is ignored: defaults, no crash")
    func corruptCache() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("Library/Caches/Homebrew/f", bytes: 2_000_000)
            let cache = ToolPathCache(file: URL(fileURLWithPath: f.path("state/tool-paths.json")))
            let key = ToolPathCache.key(binary: "/fake/bin/brew", tool: CacheTools.brew, home: f.root)
            for bad in [["/a/cache", "/b/cache"], ["relative/cache"], []] {
                cache.save(["brew": .init(key: key, paths: bad, savedAt: Date().timeIntervalSince1970)])
                let (env, _) = fakeEnvironment(f, tools: ["brew"], answers: [:], cache: cache)
                let scan = try await scanWithTools(f, env)
                #expect(scan.candidates.map(\.id) == ["homebrew-cache:Library/Caches/Homebrew"], "\(bad)")
                #expect(scan.candidates.first?.safety == .safe)
            }
        }
    }

    @Test("answers are cached by binary and key; a cached answer skips the command")
    func pathCache() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk("custom/homebrew/f", bytes: 2_000_000)
            let cache = ToolPathCache(file: URL(fileURLWithPath: f.path("state/tool-paths.json")))
            let answers: [String: CommandResult] = [
                "/fake/bin/brew --cache": .success(f.path("custom/homebrew") + "\n")
            ]
            let (env1, runner1) = fakeEnvironment(f, tools: ["brew"], answers: answers, cache: cache)
            let first = await CacheTools.discover(env1)
            #expect(runner1.calls == ["/fake/bin/brew --cache"])
            #expect(cache.load()["brew"]?.paths == [f.path("custom/homebrew")])
            let (env2, runner2) = fakeEnvironment(f, tools: ["brew"], answers: [:], cache: cache)
            let second = await CacheTools.discover(env2)
            #expect(runner2.calls.isEmpty)
            #expect(second.value["brew"] == first.value["brew"])
            // A stale entry is asked again.
            var stale = cache.load()
            stale["brew"]?.savedAt -= 8 * 86_400
            cache.save(stale)
            let (env3, runner3) = fakeEnvironment(f, tools: ["brew"], answers: answers, cache: cache)
            _ = await CacheTools.discover(env3)
            #expect(runner3.calls == ["/fake/bin/brew --cache"])
        }
    }

    @Test("the locator skips the /usr/bin/pip3 stub without developer tools")
    func locator() {
        let home = "/Users/nobody"
        #expect(ToolLocator.find("pip3", home: home, isExecutable: { $0 == "/usr/bin/pip3" }) == nil)
        #expect(
            ToolLocator.find(
                "pip3", home: home,
                isExecutable: {
                    $0 == "/usr/bin/pip3" || $0 == "/Library/Developer/CommandLineTools/usr/bin/pip3"
                }) == "/usr/bin/pip3")
        #expect(
            ToolLocator.find(
                "npm", home: home,
                isExecutable: {
                    $0 == "/usr/local/bin/npm" || $0 == "/opt/homebrew/bin/npm"
                }) == "/opt/homebrew/bin/npm")
        #expect(
            ToolLocator.find("uv", home: home, isExecutable: { $0 == home + "/.local/bin/uv" }) == home
                + "/.local/bin/uv")
    }
}

@Suite("Command timeouts (real processes)")
struct TimeoutTests {
    @Test("a hanging command times out quickly and its process is killed")
    func hangs() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let r = await SystemCommandRunner().run(["/bin/sleep", "31.4159"], timeout: .milliseconds(200))
        #expect(r == .timedOut)
        #expect(clock.now - start < .seconds(2))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "sleep 31.4159"]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1, "the sleep process is still running")
    }

    @Test("output and failures come back before the timeout")
    func finishes() async {
        #expect(await SystemCommandRunner().run(["/bin/echo", "hi"], timeout: .seconds(3)) == .success("hi\n"))
        guard case .failed = await SystemCommandRunner().run(["/usr/bin/false"], timeout: .seconds(3)) else {
            Issue.record("false did not fail")
            return
        }
        guard case .failed = await SystemCommandRunner().run(["/no/such/tool"], timeout: .seconds(3)) else {
            Issue.record("a missing binary did not fail")
            return
        }
    }

    @Test("queries run concurrently: three hanging tools cost one timeout, not three")
    func concurrent() async throws {
        try await Fixture.withAsync("tools") { f in
            let env = ToolEnvironment(
                home: f.root, runner: SystemCommandRunner(), locate: { _ in "/bin/sleep" },
                timeout: .milliseconds(300))
            let clock = ContinuousClock()
            let start = clock.now
            let answer = await CacheTools.discover(env)
            #expect(clock.now - start < .milliseconds(1500))
            // `/bin/sleep --cache` and friends fail at once or time out; either way the defaults are used.
            #expect(answer.value["brew"] == [f.path("Library/Caches/Homebrew")])
            #expect(answer.value["npm"] == [f.path(".npm/_cacache")])
        }
    }
}

let runtimesJSON = """
    {
      "8A257395-91BE-4EBE-B224-684810B04FC5" : {
        "build" : "24A434", "deletable" : true, "identifier" : "8A257395-91BE-4EBE-B224-684810B04FC5",
        "path" : "\\/System\\/Library\\/AssetsV2\\/ios\\/AssetData",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "sizeBytes" : 8067000161,
        "state" : "Ready", "version" : "27.0"
      },
      "B4C2D985-5D38-483D-8CA8-99F9423CDBD8" : {
        "build" : "24J360", "deletable" : true, "identifier" : "B4C2D985-5D38-483D-8CA8-99F9423CDBD8",
        "path" : "\\/System\\/Library\\/AssetsV2\\/tvos\\/AssetData",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.tvOS-27-0", "sizeBytes" : 3697822545,
        "state" : "Ready", "version" : "27.0"
      },
      "E389B130-C868-4AB2-B084-2B0D918BFF84" : {
        "build" : "24M362", "deletable" : true, "identifier" : "E389B130-C868-4AB2-B084-2B0D918BFF84",
        "path" : "\\/System\\/Library\\/AssetsV2\\/xros\\/AssetData",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.xrOS-27-0", "sizeBytes" : 7480076129,
        "state" : "Ready", "version" : "27.0"
      },
      "11111111-0000-0000-0000-000000000000" : {
        "build" : "24R362", "deletable" : false, "identifier" : "11111111-0000-0000-0000-000000000000",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "sizeBytes" : 3814435665,
        "version" : "27.0"
      }
    }
    """

let devicesJSON = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
          { "udid" : "EFCD106B-33B6-4324-988B-2412AA53E573", "isAvailable" : true, "name" : "iPhone" }
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0" : [ ],
        "com.apple.CoreSimulator.SimRuntime.iOS-16-0" : [
          { "udid" : "DEAD0000-0000-0000-0000-000000000001", "isAvailable" : false, "name" : "Old iPhone" }
        ]
      }
    }
    """

@Suite("Simulator runtimes")
struct SimulatorRuntimeTests {
    @Test("runtime and device JSON parse; a runtime without devices is unused; not deletable is skipped")
    func parsing() throws {
        let runtimes = try #require(Simctl.parseRuntimes(runtimesJSON))
        #expect(runtimes.map(\.slug) == ["iOS-27.0-24A434", "tvOS-27.0-24J360", "xrOS-27.0-24M362"])
        #expect(runtimes[1].sizeBytes == 3_697_822_545)
        #expect(runtimes[2].displayName == "visionOS 27.0 (24M362)")
        let devices = try #require(Simctl.parseDevices(devicesJSON))
        #expect(devices.unavailable == ["DEAD0000-0000-0000-0000-000000000001"])
        #expect(
            devices.usedRuntimes == [
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
            ])
        #expect(
            Simctl.unused(runtimes, used: devices.usedRuntimes).map(\.identifier)
                == ["B4C2D985-5D38-483D-8CA8-99F9423CDBD8", "E389B130-C868-4AB2-B084-2B0D918BFF84"])
        #expect(Simctl.parseRuntimes("not json") == nil)
        #expect(Simctl.parseDevices("{}") == nil)
    }

    @Test("unused runtimes become review candidates sized from the JSON, removed by simctl")
    func candidates() async throws {
        try await Fixture.withAsync("tools") { f in
            try f.mk(
                "Library/Developer/CoreSimulator/Devices/DEAD0000-0000-0000-0000-000000000001/data/f", bytes: 2_000_000)
            let (env, _) = fakeEnvironment(
                f, tools: ["xcrun"],
                answers: [
                    "/fake/bin/xcrun simctl list devices -j": .success(devicesJSON),
                    "/fake/bin/xcrun simctl runtime list -j": .success(runtimesJSON),
                ])
            let scan = try await scanWithTools(f, env)
            let tv = try #require(scan.candidates.first { $0.id == "simulator-runtimes:tvOS-27.0-24J360" })
            #expect(tv.bytes == 3_697_822_545)
            #expect(tv.safety == .review)
            #expect(tv.note == .simulatorRuntime(name: "tvOS 27.0 (24J360)"))
            guard case .command(let argv) = tv.removal else { Issue.record("not a command"); return }
            #expect(argv == ["/fake/bin/xcrun", "simctl", "runtime", "delete", "B4C2D985-5D38-483D-8CA8-99F9423CDBD8"])
            #expect(scan.candidates.filter { $0.ruleId == "simulator-runtimes" }.count == 2)
            let old = try #require(scan.candidates.first { $0.ruleId == "simulators-unavailable" })
            guard case .command(let del) = old.removal else { Issue.record("not a command"); return }
            #expect(del == ["/fake/bin/xcrun", "simctl", "delete", "DEAD0000-0000-0000-0000-000000000001"])
        }
    }

    @Test("a failing runtime query keeps the unavailable simulators and leaves a note")
    func runtimeQueryFails() async throws {
        try await Fixture.withAsync("tools") { f in
            let (env, _) = fakeEnvironment(
                f, tools: ["xcrun"],
                answers: [
                    "/fake/bin/xcrun simctl list devices -j": .success(devicesJSON),
                    "/fake/bin/xcrun simctl runtime list -j": .timedOut,
                ])
            let answer = await Simctl.query(env)
            #expect(answer.value.unavailableUDIDs == ["DEAD0000-0000-0000-0000-000000000001"])
            #expect(answer.value.unusedRuntimes.isEmpty)
            #expect(answer.notes == ["xcrun simctl runtime list -j: timed out after 3 s"])
        }
    }
}

// `docker system df -v --format json`, trimmed: one object.
let dockerDFVerbose = """
    {"Images":[
     {"Containers":"1","ID":"sha256:a","Repository":"postgres","SharedSize":"0B","Size":"664MB","Tag":"17","UniqueSize":"664.3MB"},
     {"Containers":"0","ID":"sha256:b","Repository":"<none>","SharedSize":"346.3MB","Size":"1.5GB","Tag":"<none>","UniqueSize":"1.2GB"},
     {"Containers":"0","ID":"sha256:c","Repository":"<none>","SharedSize":"0B","Size":"250MB","Tag":"<none>","UniqueSize":"250MB"},
     {"Containers":"2","ID":"sha256:d","Repository":"<none>","SharedSize":"0B","Size":"900MB","Tag":"<none>","UniqueSize":"900MB"}],
     "Containers":[{"ID":"x","Size":"1.396GB","State":"exited"}],
     "Volumes":[{"Name":"pgdata","Size":"378MB","Links":"1"}],
     "BuildCache":[
     {"CacheType":"regular","ID":"1","InUse":"false","Shared":"false","Size":"7.6GB"},
     {"CacheType":"exec.cachemount","ID":"2","InUse":"false","Shared":"false","Size":"2.4GB"},
     {"CacheType":"regular","ID":"3","InUse":"false","Shared":"true","Size":"8.3GB"},
     {"CacheType":"frontend","ID":"4","InUse":"false","Shared":"false","Size":"80.2MB"},
     {"CacheType":"internal","ID":"5","InUse":"false","Shared":"false","Size":"10MB"},
     {"CacheType":"regular","ID":"6","InUse":"true","Shared":"false","Size":"1GB"}]}
    """

@Suite("Docker")
struct DockerTests {
    let df = "/fake/bin/docker system df -v --format json"

    @Test("sizes parse; only what the prune commands free is counted")
    func parsing() throws {
        #expect(DockerQuery.parseSize("10.1GB") == 10_100_000_000)
        #expect(DockerQuery.parseSize("1.396GB (100%)") == 1_396_000_000)
        #expect(DockerQuery.parseSize("0B") == 0)
        #expect(DockerQuery.parseSize("512kB") == 512_000)
        #expect(DockerQuery.parseSize("1.5GiB") == 1_610_612_736)
        #expect(DockerQuery.parseSize("lots") == nil)
        let sizes = try #require(DockerQuery.parseVerboseDF(dockerDFVerbose))
        // Not in use, not shared, not frontend/internal (those need --all): 7.6 + 2.4 GB.
        #expect(sizes.buildCache == 10_000_000_000)
        // Dangling images no container uses, by unique size: 1.2 GB + 250 MB.
        #expect(sizes.danglingImages == 1_450_000_000)
        #expect(DockerQuery.parseVerboseDF("Cannot connect") == nil)
        #expect(DockerQuery.parseVerboseDF("{}") == nil)
        #expect(
            DockerQuery.parseVerboseDF(#"{"Images":[],"BuildCache":[]}"#).map { [$0.buildCache, $0.danglingImages] }
                == [0, 0])
    }

    @Test("build cache and dangling images are review candidates with prune commands; never volumes or containers")
    func candidates() async throws {
        try await Fixture.withAsync("tools") { f in
            let (env, _) = fakeEnvironment(f, tools: ["docker"], answers: [df: .success(dockerDFVerbose)])
            let scan = try await scanWithTools(f, env)
            let docker = scan.candidates.filter { $0.ruleId == "docker" }
            #expect(Set(docker.map(\.id)) == ["docker:build-cache", "docker:dangling-images"])
            for c in docker {
                #expect(c.safety == .review)
                #expect(c.note == .dockerEstimate)
            }
            let argvs = docker.compactMap { c -> [String]? in if case .command(let a) = c.removal { a } else { nil } }
            #expect(
                Set(argvs) == [
                    ["/fake/bin/docker", "builder", "prune", "-f"], ["/fake/bin/docker", "image", "prune", "-f"],
                ])
            #expect(
                !argvs.joined().contains {
                    $0.contains("volume") || $0.contains("container") || $0 == "-a" || $0 == "--all"
                })
            #expect(docker.first { $0.id == "docker:build-cache" }?.bytes == 10_000_000_000)
            #expect(docker.first { $0.id == "docker:dangling-images" }?.bytes == 1_450_000_000)
        }
    }

    @Test("daemon not running: no candidates and no message")
    func daemonDown() async throws {
        try await Fixture.withAsync("tools") { f in
            let down = CommandResult.failed("exit 1: Cannot connect to the Docker daemon")
            let (env, _) = fakeEnvironment(f, tools: ["docker"], answers: [df: down])
            let scan = try await scanWithTools(f, env)
            #expect(!scan.candidates.contains { $0.ruleId == "docker" })
            #expect(scan.skippedCommands.isEmpty)
        }
    }

    @Test("a hanging daemon leaves a note; a stopped engine app is not even asked")
    func timeoutAndStoppedApp() async throws {
        try await Fixture.withAsync("tools") { f in
            let (env, _) = fakeEnvironment(f, tools: ["docker"], answers: [df: .timedOut])
            let answer = await DockerQuery.query(env)
            #expect(answer.value == nil)
            #expect(answer.notes == ["docker system df -v --format json: timed out after 3 s"])
            let (stopped, runner) = fakeEnvironment(
                f, tools: ["docker"], answers: [df: .success(dockerDFVerbose)],
                dockerMayAutostart: true)
            #expect(await DockerQuery.query(stopped).value == nil)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("no dangling images: only the build cache")
    func noDangling() async throws {
        try await Fixture.withAsync("tools") { f in
            let json =
                #"{"Images":[],"BuildCache":[{"CacheType":"regular","InUse":"false","Shared":"false","Size":"2GB"}]}"#
            let (env, _) = fakeEnvironment(f, tools: ["docker"], answers: [df: .success(json)])
            let scan = try await scanWithTools(f, env)
            #expect(scan.candidates.filter { $0.ruleId == "docker" }.map(\.id) == ["docker:build-cache"])
        }
    }
}
