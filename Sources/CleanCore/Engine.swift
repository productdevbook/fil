import AppKit
import Foundation
import ScanCore

/// Moves one item to the Trash. A seam so tests never touch the real Trash.
public protocol Trasher: Sendable {
    /// Returns where the item ended up; nil when it moved but the system did not say where.
    func trash(_ url: URL) throws -> URL?
}

/// The real thing: `FileManager.trashItem` (the user's ~/.Trash).
public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
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
    /// `writesPathCache: false` (a dry run) keeps `tool-paths.json` from being written.
    public static func startToolQueries(home: String, environment: ToolEnvironment? = nil,
                                        writesPathCache: Bool = true) -> ToolQueries {
        if let environment { return .start(environment) }
        guard isRealHome(home) else { return .start(nil) }
        var env = ToolEnvironment.system(home: home)
        if !writesPathCache { env.pathCache = nil }
        return .start(env)
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
        /// After the move, the item in the Trash is not the one that was checked: a different item was moved.
        case movedOtherItem(URL)
        /// The item moved, but the system did not say where, so the move cannot be verified.
        case movedUnverified
        /// A removal command ran longer than allowed and was stopped (SIGTERM, then SIGKILL).
        case timedOut(seconds: Int)
        case system(String)

        public var description: String {
            switch self {
            case .pathChanged: "path changed or is not a plain directory in home; skipped"
            case .movedOtherItem(let url): "a different item was moved to the Trash at \(url.path); put it back"
            case .movedUnverified: "moved to the Trash, but the system did not say where; check the Trash"
            case .timedOut(let seconds): "timed out after \(seconds) s; the command was stopped"
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

    /// Moves or removes each candidate; one failure does not stop the others. Removal commands run through
    /// `runner` (default: the system runner in `home`, own session, SIGTERM then SIGKILL after 5 s) and are
    /// stopped after `removalTimeout`. When the calling task is cancelled the running command is stopped, it is
    /// reported as failed ("interrupted") and no further item runs.
    public static func execute(_ items: [Candidate], home: String, trasher: any Trasher = SystemTrasher(),
                               runner: (any CommandRunner)? = nil,
                               removalTimeout: Duration = .seconds(600)) async -> [(Candidate, Outcome)] {
        await executeReporting(items, home: home, trasher: trasher, runner: runner,
                               removalTimeout: removalTimeout).results
    }

    /// `execute`, also telling whether a cancellation cut it short: an item was left untouched or a running
    /// command was stopped. A cancellation after the last item finished is not "stopped early".
    public static func executeReporting(_ items: [Candidate], home: String, trasher: any Trasher = SystemTrasher(),
                                        runner: (any CommandRunner)? = nil,
                                        removalTimeout: Duration = .seconds(600))
        async -> (results: [(Candidate, Outcome)], stoppedEarly: Bool) {
        var stoppedEarly = false
        let runner = runner ?? SystemCommandRunner(workingDirectory: home, gracePeriod: .seconds(5))
        var results: [(Candidate, Outcome)] = []
        var ran: [[String]: Outcome] = [:]
        let homeDev: dev_t = { var st = stat(); return stat(home, &st) == 0 ? st.st_dev : 0 }()
        for c in items {
            // Ctrl-C: nothing more is touched, whatever the kind of the item.
            if Task.isCancelled { stoppedEarly = true; break }
            switch c.removal {
            case .none:
                results.append((c, .nothingToDo))
            case .command(let argv):
                if let prev = ran[argv] {
                    results.append((c, prev.isFailure ? prev : .commandShared))
                    continue
                }
                let outcome: Outcome
                switch await runner.run(argv, timeout: removalTimeout) {
                case .success: outcome = .commandRan
                case .failed(let why):
                    outcome = .failed(.system("\(((argv.first ?? "") as NSString).lastPathComponent) failed: \(why)"))
                case .timedOut:
                    if Task.isCancelled {
                        stoppedEarly = true
                        outcome = .failed(.system("interrupted; the command was stopped"))
                    } else {
                        outcome = .failed(.timedOut(seconds: Int(removalTimeout.components.seconds)))
                    }
                }
                results.append((c, outcome))
                ran[argv] = outcome
            case .trash:
                // Re-check right before moving (chapter 04 §7.2). A window remains between the last check and
                // `trashItem`, which takes a path; the check after the move (§7.2 step 6) detects a swap there.
                guard let id = c.fileID, stillSameItem(path: c.path, home: home, homeDev: homeDev, id: id) else {
                    results.append((c, .failed(.pathChanged)))
                    continue
                }
                do {
                    if let url = try trasher.trash(URL(fileURLWithPath: c.path)) {
                        results.append((c, movedItem(at: url, is: id) ? .trashed(url) : .failed(.movedOtherItem(url))))
                    } else {
                        results.append((c, .failed(.movedUnverified)))
                    }
                } catch {
                    results.append((c, .failed(.system(error.localizedDescription))))
                }
            }
        }
        return (results, stoppedEarly)
    }
}

extension Cleanup {
    /// Opens home, then every ancestor of `path` below it without following symlinks, and compares the last
    /// component's identity with `id`. All descriptors are closed before it returns.
    static func stillSameItem(path: String, home: String, homeDev: dev_t, id: FileID) -> Bool {
        guard path.hasPrefix(home + "/"), id.dev == homeDev else { return false }
        let components = path.dropFirst(home.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let last = components.last, !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        var fd = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == homeDev else { return false }
        for component in components.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            close(fd)
            fd = next
            guard fstat(fd, &st) == 0, st.st_dev == homeDev else { return false }
        }
        guard fstatat(fd, last, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return st.st_dev == id.dev && st.st_ino == id.ino
    }

    /// After the move: the item at `url` has the identity that was checked. A rename on one volume keeps the
    /// inode. When the system does not let us look (no access to the Trash folder), the move cannot be
    /// verified and is accepted.
    static func movedItem(at url: URL, is id: FileID) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return errno == EPERM || errno == EACCES }
        return st.st_dev == id.dev && st.st_ino == id.ino
    }
}

extension Cleanup.Outcome {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}
