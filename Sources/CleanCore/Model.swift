import Foundation
import ScanCore

public enum Safety: String, Sendable, Comparable {
    case safe, review, careful
    private var order: Int { self == .safe ? 0 : self == .review ? 1 : 2 }
    public static func < (a: Safety, b: Safety) -> Bool { a.order < b.order }
}

public enum Removal: Sendable, Equatable {
    case trash
    case command(argv: [String])
    case none
}

/// Why a candidate needs a closer look. The CLI prints `description` (English); a client localizes the cases.
public enum CandidateNote: Sendable, Equatable, CustomStringConvertible {
    case appRunning
    case macOSComponent
    case emptyTrashInFinder
    /// Build output or dependencies of a project (`kind` is the directory name); the project's manifest was
    /// last modified `daysSinceManifest` days ago.
    case projectArtifact(kind: String, daysSinceManifest: Int)
    /// A simulator runtime (`name` like "tvOS 27.0 (24J360)") that no simulator uses.
    case simulatorRuntime(name: String)
    /// The size is Docker's own figure for data inside its virtual disk.
    case dockerEstimate
    /// A tool reported a cache folder other than its default (an environment variable or a config file moved it).
    case customCacheLocation(tool: String)

    public var description: String {
        switch self {
        case .appRunning: "app is running"
        case .macOSComponent: "macOS component"
        case .emptyTrashInFinder: "Empty the Trash in Finder"
        case .projectArtifact(let kind, let days): "\(kind), manifest untouched \(days) days"
        case .simulatorRuntime(let name): "\(name), no simulator uses it"
        case .dockerEstimate: "size reported by Docker; its disk image shrinks later"
        case .customCacheLocation(let tool): "\(tool) keeps its cache in a non-default folder"
        }
    }
}

/// Device and inode of an item as seen at scan time; the Trash re-check compares them (chapter 04 §7.2).
public struct FileID: Sendable, Equatable {
    public let dev: dev_t
    public let ino: ino_t

    public init(dev: dev_t, ino: ino_t) {
        self.dev = dev
        self.ino = ino
    }
}

public struct Candidate: Sendable {
    public let id: String
    public let ruleId: String
    public let path: String
    public let bytes: Int64
    public let safety: Safety
    public let note: CandidateNote?
    public let removal: Removal
    /// Identity of the folder at scan time; nil for external candidates. A `.trash` candidate without one is
    /// never moved.
    public let fileID: FileID?

    public init(id: String, ruleId: String, path: String, bytes: Int64, safety: Safety, note: CandidateNote? = nil,
                removal: Removal = .trash, fileID: FileID? = nil) {
        self.id = id
        self.ruleId = ruleId
        self.path = path
        self.bytes = bytes
        self.safety = safety
        self.note = note
        self.removal = removal
        self.fileID = fileID
    }

    /// False for info-only items (e.g. the Trash): there is nothing a client can move or run for them.
    public var isActionable: Bool {
        if case .none = removal { return false }
        return true
    }
}

public struct Rule: Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    let run: @Sendable (RuleContext) async -> [Candidate]

    public func candidates(_ ctx: RuleContext) async -> [Candidate] { await run(ctx) }
}

/// Everything a rule needs. Rules run one after another; `claim` makes later rules skip a path.
public final class RuleContext: @unchecked Sendable {
    public let home: String
    public let tree: DiskTree
    public let runningBundleIds: Set<String>
    /// False when `--home` points elsewhere: external commands are skipped.
    public let isRealHome: Bool
    let tools: ToolQueries
    public private(set) var skippedCommands: [String] = []
    private var claimed: Set<String> = []
    /// Every ancestor (below home) of a claimed path: a folder holding a claimed candidate is not reported
    /// again as a whole (e.g. `Library/Caches/Yarn` when Yarn reported `Library/Caches/Yarn/v6`).
    private var claimedAncestors: Set<String> = []
    private var childIndex: [[Int32]]
    private let homeDev: dev_t

    public init(home: String, tree: DiskTree, runningBundleIds: Set<String>, isRealHome: Bool, tools: ToolQueries) {
        self.tools = tools
        self.home = home
        self.tree = tree
        self.runningBundleIds = runningBundleIds
        self.isRealHome = isRealHome
        var st = stat()
        homeDev = stat(home, &st) == 0 ? st.st_dev : tree.rootDev
        var idx = [[Int32]](repeating: [], count: tree.nodes.count)
        for i in tree.nodes.indices.dropFirst() where !tree.nodes[i].isDead {
            idx[Int(tree.nodes[i].parent)].append(Int32(i))
        }
        childIndex = idx
    }

    public func node(_ relative: String) -> Int? { tree.node(at: home + "/" + relative) }

    /// The tree node of an absolute path a tool reported: as given, or after resolving symlinks on both sides.
    func node(absolute path: String) -> Int? {
        if path.hasPrefix(home + "/") { return tree.node(at: path) }
        let real = resolvedPath(path), realHome = resolvedPath(home)
        guard real.hasPrefix(realHome + "/") else { return nil }
        return tree.node(at: home + real.dropFirst(realHome.count))
    }
    public func children(of id: Int) -> [Int] { childIndex[id].map(Int.init) }
    public func name(of id: Int) -> String { tree.nodes[id].name }
    func noteSkippedCommand(_ s: String) { skippedCommands.append(s) }
    func noteSkippedCommands(_ s: [String]) { skippedCommands += s }

    func relative(_ path: String) -> String {
        path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
    }

    func isClaimed(_ path: String) -> Bool {
        var p = path
        while p.count > home.count {
            if claimed.contains(p) { return true }
            guard let slash = p.lastIndex(of: "/") else { break }
            p = String(p[..<slash])
        }
        return false
    }

    /// Validates and claims a directory node as a candidate. Nil when it must not be reported.
    func make(rule: String, node id: Int, safety: Safety, note: CandidateNote? = nil, removal: Removal = .trash,
              minBytes: Int64 = 1 << 20) -> Candidate? {
        let path = tree.path(of: id)
        let bytes = tree.nodes[id].totalAlloc
        guard bytes >= minBytes, path.hasPrefix(home + "/"), !isClaimed(path) else { return nil }
        // Info-only candidates (the Trash) may contain claimed ones; anything removable must not.
        if case .none = removal {} else if claimedAncestors.contains(path) { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev == homeDev else { return nil }
        claimed.insert(path)
        var p = (path as NSString).deletingLastPathComponent
        while p.count > home.count, claimedAncestors.insert(p).inserted { p = (p as NSString).deletingLastPathComponent }
        return Candidate(id: "\(rule):\(relative(path))", ruleId: rule, path: path, bytes: bytes,
                         safety: safety, note: note, removal: removal, fileID: FileID(dev: st.st_dev, ino: st.st_ino))
    }

    /// A candidate whose data lives outside the tree (simulator runtimes, Docker): `bytes` comes from the tool,
    /// removal is the tool's own command. Nil under 1 MB.
    func makeExternal(rule: String, key: String, path: String, bytes: Int64, safety: Safety, note: CandidateNote?,
                      removal: Removal) -> Candidate? {
        guard bytes >= 1 << 20 else { return nil }
        return Candidate(id: "\(rule):\(key)", ruleId: rule, path: path, bytes: bytes, safety: safety, note: note,
                         removal: removal)
    }
}
