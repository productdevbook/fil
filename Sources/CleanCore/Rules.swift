import AppKit
import Foundation
import ScanCore

public enum Rules {
    public static let all: [Rule] = [
        Rule(id: "xcode-derived", title: "Xcode build data",
             explanation: "Temporary files Xcode creates while building apps; it recreates them when needed.") { ctx in
            childrenOf(ctx, "Library/Developer/Xcode/DerivedData").compactMap {
                ctx.make(rule: "xcode-derived", node: $0, safety: .safe)
            }
        },
        Rule(id: "xcode-device-support", title: "Xcode device support files",
             explanation: "Debug data Xcode copied from iPhones and Watches; it downloads again on next connection.") { ctx in
            guard let xcode = ctx.node("Library/Developer/Xcode") else { return [] }
            return ctx.children(of: xcode).filter { ctx.name(of: $0).hasSuffix("DeviceSupport") }
                .flatMap { ctx.children(of: $0) }
                .compactMap { ctx.make(rule: "xcode-device-support", node: $0, safety: .review) }
        },
        Rule(id: "simulators-unavailable", title: "Unavailable simulators",
             explanation: "Simulated iPhones and iPads whose system version is no longer installed.") { ctx in
            await unavailableSimulators(ctx)
        },
        Rule(id: "simulator-runtimes", title: "Unused simulator runtimes",
             explanation: "System versions for simulated devices that no simulator uses any more; Xcode downloads them again when needed.") { ctx in
            await unusedRuntimes(ctx)
        },
        Rule(id: "xcode-archives", title: "Xcode archives",
             explanation: "Saved app builds; they may be the only copy needed to debug or re-submit a released app.") { ctx in
            childrenOf(ctx, "Library/Developer/Xcode/Archives").compactMap {
                ctx.make(rule: "xcode-archives", node: $0, safety: .careful)
            }
        },
        Rule(id: "homebrew-cache", title: "Homebrew downloads",
             explanation: "Installer files Homebrew downloaded earlier; they download again if needed.") { ctx in
            await cacheLocations(ctx, [CacheTools.brew]).compactMap { loc in
                ctx.node(absolute: loc.path).flatMap {
                    ctx.make(rule: "homebrew-cache", node: $0, safety: loc.custom ? .careful : .safe, note: loc.note)
                }
            }
        },
        Rule(id: "pkg-caches", title: "Developer package caches",
             explanation: "Downloaded libraries kept by package managers (npm, pnpm, Yarn, Go, pip, uv, Cargo, Gradle, CocoaPods); they download again when a project needs them.") { ctx in
            let fixed = [".cargo/registry/cache", ".gradle/caches", "Library/Caches/CocoaPods"].map {
                CacheLocation(path: ctx.home + "/" + $0, removal: .trash)
            }
            return (await cacheLocations(ctx, CacheTools.packageManagers) + fixed).compactMap { loc in
                ctx.node(absolute: loc.path).flatMap {
                    ctx.make(rule: "pkg-caches", node: $0, safety: loc.custom ? .careful : .review, note: loc.note,
                             removal: loc.removal)
                }
            }
        },
        Rule(id: "project-artifacts", title: "Project build output and dependencies",
             explanation: "Files inside your coding projects that the project's tools can rebuild or download again.") { ctx in
            projectArtifacts(ctx)
        },
        Rule(id: "app-caches", title: "App caches",
             explanation: "Temporary files that apps keep to start faster; they recreate them when needed.") { ctx in
            childrenOf(ctx, "Library/Caches").compactMap { id in
                let name = ctx.name(of: id)
                let running = ctx.runningBundleIds.contains(name)
                let apple = name.hasPrefix("com.apple.")
                return ctx.make(rule: "app-caches", node: id, safety: running || apple ? .review : .safe,
                                note: running ? .appRunning : apple ? .macOSComponent : nil)
            }
        },
        Rule(id: "logs", title: "Logs",
             explanation: "Diagnostic text files that apps and the system write; they are only useful for troubleshooting.") { ctx in
            childrenOf(ctx, "Library/Logs").compactMap { ctx.make(rule: "logs", node: $0, safety: .safe) }
        },
        Rule(id: "docker", title: "Docker build cache and dangling images",
             explanation: "Leftovers from building container images; Docker rebuilds them when needed. Volumes and containers are never touched.") { ctx in
            await dockerCandidates(ctx)
        },
        Rule(id: "trash", title: "Trash",
             explanation: "Items you already deleted that still take space until the Trash is emptied.") { ctx in
            guard let id = ctx.node(".Trash") else { return [] }
            return ctx.make(rule: "trash", node: id, safety: .review, note: .emptyTrashInFinder,
                            removal: .none).map { [$0] } ?? []
        },
    ]

    static func childrenOf(_ ctx: RuleContext, _ rel: String) -> [Int] {
        ctx.node(rel).map { ctx.children(of: $0) } ?? []
    }

    static func projectArtifacts(_ ctx: RuleContext) -> [Candidate] {
        let tree = ctx.tree
        let nodes = tree.nodes
        // Manifest that must sit next to (or, for virtualenvs, inside) the directory.
        let manifests: [String: String] = ["node_modules": "../package.json", "target": "../Cargo.toml",
                                           ".build": "../Package.swift", "Pods": "../Podfile",
                                           ".venv": "pyvenv.cfg", "venv": "pyvenv.cfg"]
        var inside = [Bool](repeating: false, count: nodes.count)
        var out: [Candidate] = []
        let now = Date().timeIntervalSince1970
        for i in nodes.indices.dropFirst() where !nodes[i].isDead {
            let p = Int(nodes[i].parent)
            if inside[p] { inside[i] = true; continue }
            guard let manifest = manifests[nodes[i].name] else { continue }
            let dir = tree.path(of: i)
            let mpath = manifest.hasPrefix("../")
                ? (dir as NSString).deletingLastPathComponent + "/" + manifest.dropFirst(3)
                : dir + "/" + manifest
            var st = stat()
            guard lstat(mpath, &st) == 0 else { continue }
            inside[i] = true
            let days = max(0, Int((now - Double(st.st_mtimespec.tv_sec)) / 86400))
            let kind = nodes[i].name
            if let c = ctx.make(rule: "project-artifacts", node: i, safety: .review,
                                note: .projectArtifact(kind: kind, daysSinceManifest: days)) {
                out.append(c)
            }
        }
        return out
    }

    struct CacheLocation {
        let path: String
        let removal: Removal
        /// The tool keeps its cache somewhere else than its default (chapter 04 §6.7.3).
        var custom = false
        var note: CandidateNote? = nil
    }

    /// Folders that hold more than one tool's data: a tool reporting one of these (or home) as its cache is
    /// misconfigured, and trashing it would take other apps' data along.
    static let sharedLocations: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Developer", "Library/Containers",
        "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage", "Library/Preferences",
        "Library/Logs", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
        ".cache", ".config", ".local", ".local/share", ".local/state", ".Trash", "go", "go/pkg",
    ]

    /// What the location checks say about one tool-reported path.
    private enum LocationVerdict {
        /// Already reported by an earlier tool in this rule.
        case duplicate
        /// Home, a shared folder, or not below home: ignored without a message.
        case shared
        /// Too shallow or no cache marker: ignored with a `skippedCommands` line.
        case notCache(relative: String)
        case accepted(custom: Bool)
    }

    /// Absolute candidate paths reported by `tools`, or their defaults, with their removal. The Go caches are
    /// read-only on disk, so they are removed by `go clean` and only reported when `go` itself named them.
    static func cacheLocations(_ ctx: RuleContext, _ tools: [CacheTool]) async -> [CacheLocation] {
        let answer = await ctx.tools.cachePaths.value.value
        var seen: Set<String> = []
        var out: [CacheLocation] = []
        for tool in tools {
            let defaultPaths = CacheTools.defaults(tool, home: ctx.home)
            var paths = answer.paths[tool.name] ?? defaultPaths
            // Go acts on the folders Go names: a wrong answer is never replaced by guessed defaults.
            if paths.count != defaultPaths.count {
                if tool.name == "go" { continue }
                paths = defaultPaths
            }
            let removals: [Removal]
            if tool.name == "go" {
                guard let go = answer.reportedBy["go"], paths.count == 2 else { continue }
                removals = [.command(argv: [go, "clean", "-modcache"]), .command(argv: [go, "clean", "-cache"])]
            } else {
                removals = Array(repeating: .trash, count: paths.count)
            }
            let defaults = CacheTools.defaults(tool, home: resolvedPath(ctx.home))
            var verdicts: [LocationVerdict] = []
            for (i, p) in paths.enumerated() {
                verdicts.append(seen.insert(p).inserted ? verdict(p, tool: tool, defaultPath: defaults[i], ctx)
                                                        : .duplicate)
            }
            // `go clean` removes the whole directory Go names: if either Go path is refused, report neither.
            if tool.name == "go", verdicts.contains(where: {
                switch $0 { case .accepted: false; case .duplicate, .shared, .notCache: true }
            }) {
                for case .notCache(let r) in verdicts { ctx.noteSkippedCommand(notCacheLine(tool, r)) }
                continue
            }
            for (i, v) in verdicts.enumerated() {
                switch v {
                case .duplicate, .shared: break
                case .notCache(let r): ctx.noteSkippedCommand(notCacheLine(tool, r))
                case .accepted(let custom):
                    out.append(CacheLocation(path: paths[i], removal: removals[i], custom: custom,
                                             note: custom ? .customCacheLocation(tool: tool.name) : nil))
                }
            }
        }
        return out
    }

    private static func notCacheLine(_ tool: CacheTool, _ relative: String) -> String {
        "\(tool.name): reported cache ~/\(relative) does not look like a cache folder; ignored"
    }

    /// Chapter 04 §6.7.2 and §6.7.3 for one reported path, on the `realpath` of path, home and default.
    private static func verdict(_ path: String, tool: CacheTool, defaultPath: String, _ ctx: RuleContext)
        -> LocationVerdict {
        if isSharedLocation(path, ctx) { return .shared }
        let home = resolvedPath(ctx.home), real = resolvedPath(path)
        guard real.hasPrefix(home + "/") else { return .shared }
        let relative = String(real.dropFirst(home.count + 1))
        let components = relative.split(separator: "/").map { $0.lowercased() }
        guard components.count >= 2 else { return .notCache(relative: relative) }
        let def = resolvedPath(defaultPath)
        let isDefault = real == def || real.hasPrefix(def + "/")
        // The tool's own default location (or a versioned folder below it) needs no marker, unless the default
        // is a symlink somewhere below home: then "the default" could be any folder (`Homebrew` -> `Projects`).
        if isDefault, def == defaultPath {
            return .accepted(custom: false)
        }
        // The marker sits in the folder itself, or in its parent when the folder is only a version (`v6`, `10`).
        var window = components.suffix(1)
        if let last = components.last, last.drop(while: { $0 == "v" }).allSatisfy(\.isNumber) {
            window = components.suffix(2)
        }
        let marked = window.contains { c in
            c.contains("cache") || tool.markers.contains { c.contains($0) } || tool.exactMarkers.contains(c)
        }
        guard marked else { return .notCache(relative: relative) }
        return .accepted(custom: !isDefault)
    }

    static func isSharedLocation(_ path: String, _ ctx: RuleContext) -> Bool {
        let home = resolvedPath(ctx.home), real = resolvedPath(path)
        guard real.hasPrefix(home + "/") else { return real == home || home.hasPrefix(real + "/") }
        return sharedLocations.contains(String(real.dropFirst(home.count + 1)))
    }

    static func unavailableSimulators(_ ctx: RuleContext) async -> [Candidate] {
        let report = await ctx.tools.simulators.value.value
        var out: [Candidate] = []
        for udid in report.unavailableUDIDs {
            guard let id = ctx.node("Library/Developer/CoreSimulator/Devices/\(udid)"),
                  let c = ctx.make(rule: "simulators-unavailable", node: id, safety: .safe,
                                   removal: .command(argv: [report.xcrun, "simctl", "delete", udid])) else { continue }
            out.append(c)
        }
        return out
    }

    static func unusedRuntimes(_ ctx: RuleContext) async -> [Candidate] {
        let report = await ctx.tools.simulators.value.value
        return report.unusedRuntimes.compactMap { r in
            ctx.makeExternal(rule: "simulator-runtimes", key: r.slug, path: r.path.isEmpty ? r.identifier : r.path,
                             bytes: r.sizeBytes, safety: .review, note: .simulatorRuntime(name: r.displayName),
                             removal: .command(argv: [report.xcrun, "simctl", "runtime", "delete", r.identifier]))
        }
    }

    static func dockerCandidates(_ ctx: RuleContext) async -> [Candidate] {
        guard let d = await ctx.tools.docker.value.value else { return [] }
        return [
            ctx.makeExternal(rule: "docker", key: "build-cache", path: "docker:build-cache", bytes: d.buildCacheBytes,
                             safety: .review, note: .dockerEstimate,
                             removal: .command(argv: [d.docker, "builder", "prune", "-f"])),
            ctx.makeExternal(rule: "docker", key: "dangling-images", path: "docker:dangling-images",
                             bytes: d.danglingImageBytes, safety: .review, note: .dockerEstimate,
                             removal: .command(argv: [d.docker, "image", "prune", "-f"])),
        ].compactMap { $0 }
    }
}
