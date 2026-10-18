import AppKit
import Foundation
import ScanCore

/// Moves one item to the Trash. A seam so tests never touch the real Trash.
public protocol Trasher: Sendable {
    /// Returns where the item ended up.
    func trash(_ url: URL) throws -> URL
}

/// The real thing: `FileManager.trashItem` (the user's ~/.Trash).
public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL? ?? url
    }
}

public enum Cleanup {
    public struct Scan: Sendable {
        public let home: String
        public let candidates: [Candidate]
        public let skippedCommands: [String]
        /// Seconds spent in each rule, in run order.
        public let ruleTimes: [(rule: String, seconds: Double)]
    }

    public static func isRealHome(_ home: String) -> Bool {
        realpath(home) == realpath(NSHomeDirectory())
    }

    private static func realpath(_ p: String) -> String {
        guard let r = Darwin.realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }

    /// Starts every external query (simctl, docker, cache locations) concurrently, so they run while the tree
    /// is being loaded or updated. Nothing runs when `home` is not the real home. `environment` replaces the
    /// real tools (tests).
    public static func startToolQueries(home: String, environment: ToolEnvironment? = nil) -> ToolQueries {
        if let environment { return .start(environment) }
        return .start(isRealHome(home) ? .system(home: home) : nil)
    }

    /// Former name of `startToolQueries(home:)`; starts all tool queries, not only simctl.
    public static func startSimulatorQuery(home: String) -> ToolQueries { startToolQueries(home: home) }

    /// Former label of `scan(home:tree:tools:)`.
    public static func scan(home: String, tree: DiskTree, simulators: ToolQueries) async -> Scan {
        await scan(home: home, tree: tree, tools: simulators)
    }

    /// Runs every rule in order against the tree of `home`.
    public static func scan(home: String, tree: DiskTree, tools: ToolQueries) async -> Scan {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ctx = RuleContext(home: tree.rootPath, tree: tree, runningBundleIds: running, isRealHome: isRealHome(home),
                              tools: tools)
        if let why = tools.skippedReason { ctx.noteSkippedCommand(why) }
        var all: [Candidate] = []
        var times: [(String, Double)] = []
        let clock = ContinuousClock()
        for rule in Rules.all {
            let t = clock.now
            all += await rule.candidates(ctx)
            let (s, a) = (clock.now - t).components
            times.append((rule.id, Double(s) + Double(a) / 1e18))
        }
        ctx.noteSkippedCommands(await tools.cachePaths.value.notes + tools.simulators.value.notes
            + tools.docker.value.notes)
        return Scan(home: ctx.home, candidates: all.sorted { $0.bytes > $1.bytes },
                    skippedCommands: ctx.skippedCommands, ruleTimes: times)
    }

    public enum Outcome: Sendable {
        case trashed(URL)
        case commandRan
        case commandShared      // same command already ran for another candidate
        case nothingToDo
        case failed(Failure)
    }

    /// Why one item failed. Our own reasons are typed so the app can localize them; system errors keep the
    /// system's (already localized) description.
    public enum Failure: Sendable, Equatable, CustomStringConvertible {
        /// The path is no longer a plain directory inside home on the home volume.
        case pathChanged
        case system(String)

        public var description: String {
            switch self {
            case .pathChanged: "path changed or is not a plain directory in home; skipped"
            case .system(let text): text
            }
        }
    }

    public struct Resolution: Sendable {
        /// Candidates to act on, in selector order, without duplicates.
        public let chosen: [Candidate]
        /// Careful candidates of a rule that was named: left out, because they need their own id.
        public let leftOut: [Candidate]
    }

    public struct NoMatch: Error, Equatable, CustomStringConvertible {
        public let selector: String
        public init(selector: String) { self.selector = selector }
        public var description: String { "nothing matches '\(selector)'" }
    }

    /// Turns command-line selectors into candidates. A candidate id selects that candidate (careful ones
    /// included); a rule id selects its safe and review candidates only. Throws `NoMatch` for an unknown selector.
    public static func resolve(_ selectors: [String], in candidates: [Candidate]) throws -> Resolution {
        var chosen: [Candidate] = []
        var leftOut: [Candidate] = []
        for s in selectors {
            var m = candidates.filter { $0.id == s }
            if m.isEmpty {
                let ofRule = candidates.filter { $0.ruleId == s }
                m = ofRule.filter { $0.safety != .careful }
                leftOut += ofRule.filter { $0.safety == .careful }
                if ofRule.isEmpty { throw NoMatch(selector: s) }
            }
            for c in m where !chosen.contains(where: { $0.id == c.id }) { chosen.append(c) }
        }
        return Resolution(chosen: chosen, leftOut: leftOut)
    }

    /// Moves or removes each candidate; one failure does not stop the others.
    public static func execute(_ items: [Candidate], home: String,
                               trasher: any Trasher = SystemTrasher()) async -> [(Candidate, Outcome)] {
        var results: [(Candidate, Outcome)] = []
        var ran: [[String]: Outcome] = [:]
        let homeDev: dev_t = { var st = stat(); return stat(home, &st) == 0 ? st.st_dev : 0 }()
        for c in items {
            switch c.removal {
            case .none:
                results.append((c, .nothingToDo))
            case .command(let argv):
                if let prev = ran[argv] {
                    results.append((c, prev.isFailure ? prev : .commandShared))
                    continue
                }
                let outcome: Outcome
                do { _ = try await Commands.output(argv, workingDirectory: home); outcome = .commandRan } catch {
                    outcome = .failed(.system("\(error)"))
                }
                ran[argv] = outcome
                results.append((c, outcome))
            case .trash:
                // Re-check right before moving: still a real directory inside home, same volume.
                var st = stat()
                guard c.path.hasPrefix(home + "/"), lstat(c.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                      st.st_dev == homeDev else {
                    results.append((c, .failed(.pathChanged)))
                    continue
                }
                do {
                    results.append((c, .trashed(try trasher.trash(URL(fileURLWithPath: c.path)))))
                } catch {
                    results.append((c, .failed(.system(error.localizedDescription))))
                }
            }
        }
        return results
    }
}

extension Cleanup.Outcome {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}
