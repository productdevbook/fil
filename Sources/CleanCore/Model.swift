import Foundation
import ScanCore

public enum Safety: String, Sendable, Comparable {
    case safe, review, careful
    private var order: Int { self == .safe ? 0 : self == .review ? 1 : 2 }
    public static func < (a: Safety, b: Safety) -> Bool { a.order < b.order }
}

public enum Removal: Sendable {
    case trash
    case command(argv: [String])
    case none
}

/// Why a candidate needs a closer look. The CLI prints `description` (English); the app localizes the cases.
public enum CandidateNote: Sendable, Equatable, CustomStringConvertible {
    case appRunning
    case macOSComponent
    case emptyTrashInFinder
    /// Build output or dependencies of a project (`kind` is the directory name); the project's manifest was
    /// last modified `daysSinceManifest` days ago.
    case projectArtifact(kind: String, daysSinceManifest: Int)

    public var description: String {
        switch self {
        case .appRunning: "app is running"
        case .macOSComponent: "macOS component"
        case .emptyTrashInFinder: "Empty the Trash in Finder"
        case .projectArtifact(let kind, let days): "\(kind), manifest untouched \(days) days"
        }
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

    public init(id: String, ruleId: String, path: String, bytes: Int64, safety: Safety, note: CandidateNote? = nil,
                removal: Removal = .trash) {
        self.id = id
        self.ruleId = ruleId
        self.path = path
        self.bytes = bytes
        self.safety = safety
        self.note = note
        self.removal = removal
    }

    /// False for info-only items (e.g. the Trash): there is nothing the app can move or run for them.
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
    let simulatorUDIDs: Task<[String], Never>
    public private(set) var skippedCommands: [String] = []
    private var claimed: Set<String> = []
    private var childIndex: [[Int32]]
    private let homeDev: dev_t

    public init(home: String, tree: DiskTree, runningBundleIds: Set<String>, isRealHome: Bool,
                simulatorUDIDs: Task<[String], Never>) {
        self.simulatorUDIDs = simulatorUDIDs
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
    public func children(of id: Int) -> [Int] { childIndex[id].map(Int.init) }
    public func name(of id: Int) -> String { tree.nodes[id].name }
    func noteSkippedCommand(_ s: String) { skippedCommands.append(s) }

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
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev == homeDev else { return nil }
        claimed.insert(path)
        return Candidate(id: "\(rule):\(relative(path))", ruleId: rule, path: path, bytes: bytes,
                         safety: safety, note: note, removal: removal)
    }
}
