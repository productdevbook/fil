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
        Rule(id: "xcode-archives", title: "Xcode archives",
             explanation: "Saved app builds; they may be the only copy needed to debug or re-submit a released app.") { ctx in
            childrenOf(ctx, "Library/Developer/Xcode/Archives").compactMap {
                ctx.make(rule: "xcode-archives", node: $0, safety: .careful)
            }
        },
        Rule(id: "homebrew-cache", title: "Homebrew downloads",
             explanation: "Installer files Homebrew downloaded earlier; they download again if needed.") { ctx in
            ctx.node("Library/Caches/Homebrew").flatMap { ctx.make(rule: "homebrew-cache", node: $0, safety: .safe) }
                .map { [$0] } ?? []
        },
        Rule(id: "pkg-caches", title: "Developer package caches",
             explanation: "Downloaded libraries kept by npm, Cargo, Gradle and CocoaPods; they download again when a project needs them.") { ctx in
            [".npm/_cacache", ".cargo/registry/cache", ".gradle/caches", "Library/Caches/CocoaPods"].compactMap { rel in
                ctx.node(rel).flatMap { ctx.make(rule: "pkg-caches", node: $0, safety: .review) }
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

    static func unavailableSimulators(_ ctx: RuleContext) async -> [Candidate] {
        let udids = await ctx.simulatorUDIDs.value
        if !ctx.isRealHome {
            ctx.noteSkippedCommand("xcrun simctl list devices unavailable (not the real home)")
            return []
        }
        var out: [Candidate] = []
        let xcrun = "/usr/bin/xcrun"
        for udid in udids {
            guard let id = ctx.node("Library/Developer/CoreSimulator/Devices/\(udid)"),
                  let c = ctx.make(rule: "simulators-unavailable", node: id, safety: .safe,
                                   removal: .command(argv: [xcrun, "simctl", "delete", udid])) else { continue }
            out.append(c)
        }
        return out
    }

    /// `xcrun simctl list devices unavailable`: the UDIDs of simulators whose runtime is gone.
    static func listUnavailableUDIDs() async -> [String] {
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun),
              let json = try? await Commands.output([xcrun, "simctl", "list", "devices", "unavailable", "-j"]),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let runtimes = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
    }
}
