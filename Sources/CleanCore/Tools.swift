import AppKit
import Foundation
import ScanCore

/// How the rules reach external tools: where binaries are, how commands run, how long they may take.
/// Every part is replaceable so tests run without the real tools.
public struct ToolEnvironment: Sendable {
    public var home: String
    public var runner: any CommandRunner
    /// Tool name (`npm`) to an absolute executable path, or nil when the tool is not installed.
    public var locate: @Sendable (String) -> String?
    /// Per query; on timeout the child's process group is killed.
    public var timeout: Duration
    /// Remembers tool-reported cache paths between runs; nil = always ask.
    public var pathCache: ToolPathCache?
    /// True when talking to the Docker socket could start a stopped engine app (OrbStack, Docker Desktop, ...).
    public var dockerMayAutostart: @Sendable () -> Bool

    public init(home: String, runner: any CommandRunner, locate: @escaping @Sendable (String) -> String?,
                timeout: Duration = .seconds(3), pathCache: ToolPathCache? = nil,
                dockerMayAutostart: @escaping @Sendable () -> Bool = { false }) {
        self.home = home
        self.runner = runner
        self.locate = locate
        self.timeout = timeout
        self.pathCache = pathCache
        self.dockerMayAutostart = dockerMayAutostart
    }

    /// The real tools of the real home.
    public static func system(home: String) -> ToolEnvironment {
        ToolEnvironment(home: home, runner: SystemCommandRunner(workingDirectory: home),
                        locate: { ToolLocator.find($0, home: home) }, pathCache: .standard,
                        dockerMayAutostart: { DockerQuery.engineAppStopped() })
    }

    func describe(_ argv: [String]) -> String {
        ([(argv.first.map { ($0 as NSString).lastPathComponent }) ?? ""] + argv.dropFirst()).joined(separator: " ")
    }

    func reason(_ r: CommandResult) -> String {
        switch r {
        case .success: "unexpected output"
        case .failed(let why): why
        case .timedOut: "timed out after \(timeout.components.seconds) s"
        }
    }
}

/// Finds tool binaries without a shell.
public enum ToolLocator {
    public static func searchDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/Library/pnpm",
         home + "/.docker/bin", home + "/.orbstack/bin", "/usr/bin", "/bin"]
    }

    /// `/usr/bin` stubs that open the "install developer tools" dialog when no developer directory exists;
    /// each needs one of the listed real binaries.
    static let developerStubs: [String: [String]] = [
        "pip3": ["/Library/Developer/CommandLineTools/usr/bin/pip3",
                 "/Applications/Xcode.app/Contents/Developer/usr/bin/pip3"],
    ]

    public static func find(_ name: String, home: String,
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> String? {
        for dir in searchDirectories(home: home) {
            let p = dir + "/" + name
            guard isExecutable(p) else { continue }
            if dir == "/usr/bin", let real = developerStubs[name], !real.contains(where: isExecutable) { continue }
            return p
        }
        return nil
    }
}

/// One line per tool query that failed or timed out; shown as "Skipped: ..." by the CLI.
public struct ToolAnswer<Value: Sendable>: Sendable {
    public var value: Value
    public var notes: [String]
}

/// The external queries, started before the tree is loaded so they overlap it.
public struct ToolQueries: Sendable {
    let cachePaths: Task<ToolAnswer<CachePathReport>, Never>
    let simulators: Task<ToolAnswer<SimulatorReport>, Never>
    let docker: Task<ToolAnswer<DockerReport?>, Never>
    /// Set when no tool runs at all (e.g. `--home` is not the real home).
    let skippedReason: String?

    /// Starts every query concurrently. `nil` environment: no tool runs; cache rules use default paths.
    public static func start(_ env: ToolEnvironment?) -> ToolQueries {
        guard let env else { return none(reason: "external commands (not the real home)") }
        return ToolQueries(cachePaths: Task { await CacheTools.discover(env) },
                           simulators: Task { await Simctl.query(env) },
                           docker: Task { await DockerQuery.query(env) }, skippedReason: nil)
    }

    /// No tool runs.
    public static func none(reason: String? = nil) -> ToolQueries {
        ToolQueries(cachePaths: Task { ToolAnswer(value: CachePathReport(), notes: []) },
                    simulators: Task { ToolAnswer(value: SimulatorReport(), notes: []) },
                    docker: Task { ToolAnswer(value: nil, notes: []) }, skippedReason: reason)
    }
}

// MARK: - Cache locations

/// Candidate cache paths per tool, and which tools actually reported theirs.
public struct CachePathReport: Sendable, Equatable {
    /// Tool name to candidate paths: reported by the tool (now or from the path cache), or the defaults.
    public var paths: [String: [String]] = [:]
    /// Tool name to the binary that reported `paths` (absent when the defaults are used).
    public var reportedBy: [String: String] = [:]

    public subscript(_ tool: String) -> [String]? { paths[tool] }
}

/// A tool that reports where its download cache lives.
struct CacheTool: Sendable {
    let name: String
    let args: [String]
    /// Candidate paths relative to home when the tool is missing or fails, in the order the query prints them.
    let defaults: [String]
    /// Appended to each reported path (npm keeps its downloads in `<cache>/_cacache`).
    var subpath: String? = nil
    /// Relative to home; their mtimes are part of the cache key.
    var configFiles: [String] = []
    /// Environment variables that move the cache; part of the cache key.
    var envKeys: [String] = []

    var argv: [String] { [name] + args }
}

enum CacheTools {
    static let brew = CacheTool(name: "brew", args: ["--cache"], defaults: ["Library/Caches/Homebrew"],
                                configFiles: [".homebrew/brew.env"], envKeys: ["HOMEBREW_CACHE", "XDG_CACHE_HOME"])
    static let packageManagers: [CacheTool] = [
        CacheTool(name: "npm", args: ["config", "get", "cache"], defaults: [".npm"], subpath: "_cacache",
                  configFiles: [".npmrc"], envKeys: ["npm_config_cache", "NPM_CONFIG_CACHE"]),
        CacheTool(name: "pnpm", args: ["store", "path"], defaults: ["Library/pnpm/store"],
                  configFiles: ["Library/Preferences/pnpm/rc", ".npmrc"],
                  envKeys: ["PNPM_HOME", "npm_config_store_dir", "XDG_DATA_HOME"]),
        CacheTool(name: "yarn", args: ["cache", "dir"], defaults: ["Library/Caches/Yarn"],
                  configFiles: [".yarnrc", ".yarnrc.yml"], envKeys: ["YARN_CACHE_FOLDER", "XDG_CACHE_HOME"]),
        CacheTool(name: "go", args: ["env", "GOMODCACHE", "GOCACHE"],
                  defaults: ["go/pkg/mod", "Library/Caches/go-build"],
                  configFiles: ["Library/Application Support/go/env"],
                  envKeys: ["GOPATH", "GOMODCACHE", "GOCACHE", "GOENV"]),
        CacheTool(name: "pip3", args: ["cache", "dir"], defaults: ["Library/Caches/pip"],
                  configFiles: [".config/pip/pip.conf", "Library/Application Support/pip/pip.conf", ".pip/pip.conf"],
                  envKeys: ["PIP_CACHE_DIR", "PIP_CONFIG_FILE", "XDG_CACHE_HOME"]),
        CacheTool(name: "uv", args: ["cache", "dir"], defaults: [".cache/uv"],
                  configFiles: [".config/uv/uv.toml"], envKeys: ["UV_CACHE_DIR", "XDG_CACHE_HOME"]),
    ]
    static var all: [CacheTool] { [brew] + packageManagers }

    /// Default candidate paths of `tool` under `home`.
    static func defaults(_ tool: CacheTool, home: String) -> [String] {
        tool.defaults.map { apply(tool, home + "/" + $0) }
    }

    static func apply(_ tool: CacheTool, _ path: String) -> String {
        tool.subpath.map { path + "/" + $0 } ?? path
    }

    /// The query's answer: one absolute path per line, as many as the tool's defaults. Nil otherwise.
    static func parse(_ output: String, for tool: CacheTool) -> [String]? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == tool.defaults.count, lines.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return lines.map { URL(fileURLWithPath: $0).standardized.path }
    }

    /// Tool name to candidate paths (reported, or the defaults). Missing tools are silent; failures add a note.
    static func discover(_ env: ToolEnvironment) async -> ToolAnswer<CachePathReport> {
        let stored = env.pathCache?.load() ?? [:]
        let now = Date().timeIntervalSince1970
        typealias Result = (name: String, paths: [String], reportedBy: String?, note: String?, entry: ToolPathCache.Entry?)
        let results = await withTaskGroup(of: Result.self) { group in
            for tool in all {
                group.addTask {
                    let fallback = defaults(tool, home: env.home)
                    guard let exe = env.locate(tool.name) else { return (tool.name, fallback, nil, nil, nil) }
                    let key = ToolPathCache.key(binary: exe, tool: tool, home: env.home)
                    if let e = stored[tool.name], e.key == key, e.isFresh(now: now) {
                        if let paths = e.paths { return (tool.name, paths.map { apply(tool, $0) }, exe, nil, e) }
                        return (tool.name, fallback, nil, nil, e)
                    }
                    let argv = [exe] + tool.args
                    let r = await env.runner.run(argv, timeout: env.timeout)
                    if case .success(let out) = r, let paths = parse(out, for: tool) {
                        return (tool.name, paths.map { apply(tool, $0) }, exe, nil,
                                .init(key: key, paths: paths, savedAt: now))
                    }
                    let note = "\(env.describe(argv)): \(env.reason(r)); using the default location"
                    // A timeout is not remembered: the tool may just have been slow this once.
                    let entry: ToolPathCache.Entry? = r == .timedOut ? nil : .init(key: key, paths: nil, savedAt: now)
                    return (tool.name, fallback, nil, note, entry)
                }
            }
            var all: [Result] = []
            for await r in group { all.append(r) }
            return all
        }
        var value = CachePathReport()
        var notes: [String] = []
        var entries = stored
        for r in results {
            value.paths[r.name] = r.paths
            value.reportedBy[r.name] = r.reportedBy
            if let note = r.note { notes.append(note) }
            entries[r.name] = r.entry
        }
        if let cache = env.pathCache, entries != stored { cache.save(entries) }
        return ToolAnswer(value: value, notes: notes.sorted())
    }
}

/// Tool-reported cache paths kept between runs, so slow tools (npm, pip: about 1 s) are not asked every time.
/// Keyed by the binary's resolved path and mtime, the tool's config files' mtimes and its environment variables.
public struct ToolPathCache: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    /// `tool-paths.json` next to the snapshots.
    public static var standard: ToolPathCache {
        ToolPathCache(file: Snapshot.url(for: "/").deletingLastPathComponent()
            .appendingPathComponent("tool-paths.json"))
    }

    struct Entry: Codable, Equatable, Sendable {
        var key: String
        /// Nil: the query failed; use the defaults.
        var paths: [String]?
        var savedAt: Double

        func isFresh(now: Double) -> Bool {
            let age = now - savedAt
            return age >= 0 && age < (paths == nil ? 86_400 : 7 * 86_400)
        }
    }

    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func key(binary: String, tool: CacheTool, home: String) -> String {
        func mtime(_ p: String) -> String {
            var st = stat()
            guard stat(p, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        let real = resolvedPath(binary)
        let env = ProcessInfo.processInfo.environment
        var parts = [real, mtime(real), tool.argv.joined(separator: " ")]
        parts += tool.configFiles.map { "\($0)=\(mtime(home + "/" + $0))" }
        parts += tool.envKeys.map { "\($0)=\(env[$0] ?? "")" }
        return parts.joined(separator: "|")
    }
}
