import Darwin
import Foundation

/// The firmlinks of the macOS volume group (`/usr/share/firmlinks`): directories on the sealed system volume that
/// lead into the data volume, e.g. `/Users` -> `/System/Volumes/Data/Users`. Both volumes report the same device,
/// so a scan of `/` reaches every such directory twice. See docs/specs/accounting.md.
public struct FirmlinkTable: Sendable, Equatable {
    public struct Link: Sendable, Equatable {
        /// Absolute path on the system volume, e.g. "/Users".
        public let source: String
        /// Path relative to the data volume root, e.g. "Users".
        public let target: String

        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }
    }

    /// A data-volume directory that a scan reaches through a firmlink inside the scanned tree as well.
    public struct Alias: Sendable, Equatable {
        /// Where the data volume shows it, e.g. "/System/Volumes/Data/Users": not descended into.
        public let dataPath: String
        /// The firmlink through which it is scanned, e.g. "/Users".
        public let source: String

        public init(dataPath: String, source: String) {
            self.dataPath = dataPath
            self.source = source
        }
    }

    /// Mount point of the data volume, e.g. "/System/Volumes/Data".
    public let dataRoot: String
    public let links: [Link]

    public init(dataRoot: String, links: [Link]) {
        self.dataRoot = dataRoot
        self.links = links
    }

    public static let empty = FirmlinkTable(dataRoot: "", links: [])

    /// The running system's table, read once.
    public static let system = load()

    /// Reads `file`; empty when it is missing or `dataRoot` is not a mount point (no volume group).
    public static func load(file: String = "/usr/share/firmlinks", dataRoot: String = "/System/Volumes/Data") -> FirmlinkTable {
        var fs = statfs()
        guard statfs(dataRoot, &fs) == 0 else { return .empty }
        let mountPoint = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard mountPoint == dataRoot, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return .empty }
        return parse(text, dataRoot: dataRoot)
    }

    /// One firmlink per line: absolute source, a tab, target relative to the data volume root.
    public static func parse(_ text: String, dataRoot: String) -> FirmlinkTable {
        var links: [Link] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let source = normalize(String(parts[0]))
            let target = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard source.hasPrefix("/"), source != "/", !target.isEmpty else { continue }
            links.append(Link(source: source, target: target))
        }
        return FirmlinkTable(dataRoot: normalize(dataRoot), links: links)
    }

    /// The data-volume directories a scan of `root` must skip because it reaches them through their firmlink:
    /// those whose firmlink source is inside `root` (or is `root`) and whose data path is strictly inside `root`.
    /// Empty for any scan that does not cover both views, e.g. a home folder or the data volume itself.
    public func aliases(for root: String) -> [Alias] {
        guard !dataRoot.isEmpty else { return [] }
        let root = Self.normalize(root)
        return links.compactMap { l in
            let dataPath = dataRoot + "/" + l.target
            guard Self.isInside(l.source, root, orEqual: true), Self.isInside(dataPath, root, orEqual: false) else { return nil }
            return Alias(dataPath: dataPath, source: l.source)
        }
        .sorted { $0.dataPath < $1.dataPath }
    }

    /// The data-volume spelling of a path given through a firmlink (`/private/tmp/x` →
    /// `/System/Volumes/Data/private/tmp/x`), or nil when `path` is under no firmlink. The longest source wins.
    public func dataVolumePath(_ path: String) -> String? {
        guard !dataRoot.isEmpty else { return nil }
        var best: Link?
        for l in links where Self.isInside(path, l.source, orEqual: true) && l.source.count > (best?.source.count ?? 0) {
            best = l
        }
        guard let l = best else { return nil }
        return dataRoot + "/" + l.target + path.dropFirst(l.source.count)
    }

    /// The firmlink spelling of a data-volume path (`/System/Volumes/Data/private/tmp/x` → `/private/tmp/x`), the
    /// reverse of `dataVolumePath`; nil when `path` is under no firmlink's target. The longest target wins.
    public func firmlinkPath(_ path: String) -> String? {
        guard !dataRoot.isEmpty else { return nil }
        var best: (link: Link, dataPath: String)?
        for l in links {
            let dataPath = dataRoot + "/" + l.target
            if Self.isInside(path, dataPath, orEqual: true) && dataPath.count > (best?.dataPath.count ?? 0) {
                best = (l, dataPath)
            }
        }
        guard let best else { return nil }
        return best.link.source + path.dropFirst(best.dataPath.count)
    }

    /// `root` lies on the data volume (or is its mount point) and holds a firmlink's target below it, e.g.
    /// `/System/Volumes/Data/usr` holds `usr/local`. Changes in that target are reported under the firmlink path
    /// (`/usr/local/...`), which is not a spelling of `root`.
    public func holdsFirmlinkTargets(_ root: String) -> Bool {
        guard !dataRoot.isEmpty else { return false }
        let root = Self.normalize(root)
        guard Self.isInside(root, dataRoot, orEqual: true) else { return false }
        return links.contains { Self.isInside(dataRoot + "/" + $0.target, root, orEqual: false) }
    }

    static func isInside(_ path: String, _ root: String, orEqual: Bool) -> Bool {
        if path == root { return orEqual }
        return root == "/" || path.hasPrefix(root + "/")
    }

    static func normalize(_ p: String) -> String {
        var s = Substring(p)
        while s.count > 1 && s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }
}

extension [FirmlinkTable.Alias] {
    /// Directory path -> names of children not to descend into, as `DirReader` looks them up.
    var exclusions: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for a in self {
            let slash = a.dataPath.lastIndex(of: "/")!
            let parent = slash == a.dataPath.startIndex ? "/" : String(a.dataPath[..<slash])
            out[parent, default: []].insert(String(a.dataPath[a.dataPath.index(after: slash)...]))
        }
        return out
    }

    /// Rewrites a data-volume path that is skipped by this scan to the firmlink path it is scanned under.
    func translate(_ path: Substring) -> Substring {
        for a in self where path.hasPrefix(a.dataPath) {
            let rest = path.dropFirst(a.dataPath.count)
            if rest.isEmpty || rest.hasPrefix("/") { return Substring(a.source + rest) }
        }
        return path
    }
}
