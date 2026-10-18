import Darwin
import Foundation

/// One record per scanned directory. Files are not stored individually; they roll up into their directory.
/// Invariant: a child always has a larger id than its parent, so totals are one reverse pass.
public struct DirNode: Sendable {
    public static let dead: Int32 = -2

    public var parent: Int32
    /// The directory exists but could not be listed (permissions); it then has no own sizes and no children,
    /// like in a full scan. Stored right after `parent`, in its padding.
    public var unreadable = false
    public var name: String
    /// Files directly inside this directory only.
    public var ownAlloc: Int64 = 0
    public var ownLogical: Int64 = 0
    public var ownFiles: Int64 = 0
    /// Including subdirectories (filled by `computeTotals`).
    public var totalAlloc: Int64 = 0
    public var totalLogical: Int64 = 0
    public var totalFiles: Int64 = 0
    public var totalDirs: Int64 = 0

    public var isDead: Bool { parent == DirNode.dead }
}

public struct ScanOptions: Sendable {
    public var threads: Int
    /// For APFS clones, count only blocks private to this file (ATTR_CMNEXT_PRIVATESIZE).
    public var privateSize: Bool
    public var crossDevices: Bool
    /// Incremental updates: a multiply-linked file older than the tree and unknown to it fails the update
    /// (strict), or is counted where it was found and added to `DiskTree.uncertainBytes` (tolerant).
    public var strictHardlinks: Bool

    // Measured on M-series + APFS: throughput plateaus around 8 threads (kernel-bound beyond that).
    public init(threads: Int = 8, privateSize: Bool = false, crossDevices: Bool = false, strictHardlinks: Bool = true) {
        self.threads = max(1, threads)
        self.strictHardlinks = strictHardlinks
        self.privateSize = privateSize
        self.crossDevices = crossDevices
    }
}

public struct ScanStats: Sendable {
    public var openErrors = 0          // directories that could not be opened (mostly TCC / permissions)
    public var entryErrors = 0
    public var hardlinkDupes = 0       // hard links not counted twice
    public var datalessDirs = 0        // iCloud/Dropbox placeholder dirs — never downloaded or entered
    public var datalessLogical: Int64 = 0
    public var mountsSkipped = 0

    public init() {}

    mutating func merge(_ o: ScanStats) {
        openErrors += o.openErrors
        entryErrors += o.entryErrors
        hardlinkDupes += o.hardlinkDupes
        datalessDirs += o.datalessDirs
        datalessLogical += o.datalessLogical
        mountsSkipped += o.mountsSkipped
    }
}

/// Tracks every multiply-linked inode so each hard link is counted once. Per inode it keeps the directory
/// that owns (counts) it, its sizes, and every other directory where a link was seen. This lets a directory's
/// records be dropped when it is re-read, and lets ownership move to another live link when the owner loses its own.
final class HardlinkRegistry: @unchecked Sendable {
    struct Entry {
        /// Directory that counts this inode; -1 while released and not yet re-claimed.
        var owner: Int32
        var alloc: Int64
        var logical: Int64
        /// Other directories where a link was seen (never contains `owner`).
        var others: [Int32] = []
    }

    private let lock = NSLock()
    private(set) var table: [UInt64: Entry]
    private var hasOrphans = false
    /// Set only during an incremental update (`beginUpdate`): scan-start time (ns since epoch) of the snapshot.
    private(set) var birthCutoff: Int64?
    private var strict = true
    /// An inode with several links, born before `birthCutoff`, unknown to the registry was met: it was counted
    /// as a single-link file somewhere we cannot identify (the result is uncertain by its size).
    private(set) var unattributed = false
    /// Paths of the first unattributed files found (for diagnosis), at most `maxUnattributedPaths`.
    private(set) var unattributedPaths: [String] = []
    private let maxUnattributedPaths = 20
    /// Unattributed inodes of this update, each counted once in `unattributedAlloc`.
    private var unattributedInodes: Set<UInt64> = []
    private(set) var unattributedAlloc: Int64 = 0
    /// Non-nil only during an incremental update; see `trackDrift`.
    private var drift: [Int32: (alloc: Int64, logical: Int64)]?

    init(_ table: [UInt64: Entry] = [:]) { self.table = table }

    /// Records a link to `inode` seen in `dir`. True if `dir` should count the size (it is, or just became, the owner).
    func claim(_ inode: UInt64, by dir: Int32, alloc: Int64, logical: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let i = table.index(forKey: inode) else {
            table[inode] = Entry(owner: dir, alloc: alloc, logical: logical)
            return true
        }
        let owner = table.values[i].owner
        if owner == dir { return false }
        if owner < 0 {
            table.values[i].owner = dir
            table.values[i].alloc = alloc
            table.values[i].logical = logical
            if !table.values[i].others.isEmpty { table.values[i].others.removeAll { $0 == dir } }
            return true
        }
        if !table.values[i].others.contains(dir) { table.values[i].others.append(dir) }
        // Sizes differ only when the file changed since the owner counted it (incremental updates).
        if table.values[i].alloc != alloc || table.values[i].logical != logical {
            drift?[owner, default: (0, 0)].alloc += alloc - table.values[i].alloc
            drift?[owner, default: (0, 0)].logical += logical - table.values[i].logical
            table.values[i].alloc = alloc
            table.values[i].logical = logical
        }
        return false
    }

    /// Incremental only: starts recording size changes seen through a link outside the owning directory.
    func trackDrift() {
        lock.lock()
        drift = [:]
        lock.unlock()
    }

    /// Returns, per owner directory, how much its counted size must change, and stops recording.
    func takeDrift() -> [Int32: (alloc: Int64, logical: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        let out = drift ?? [:]
        drift = nil
        return out
    }

    /// Starts an incremental update of a tree scanned at `cutoff`; clears what the previous update found.
    func beginUpdate(cutoff: Int64, strict: Bool) {
        lock.lock()
        birthCutoff = cutoff
        self.strict = strict
        unattributed = false
        unattributedPaths = []
        unattributedInodes = []
        unattributedAlloc = 0
        lock.unlock()
    }

    func endUpdate() {
        lock.lock()
        birthCutoff = nil
        unattributedInodes = []
        lock.unlock()
    }

    /// Incremental only: flags a multiply-linked file that predates the snapshot but has no record.
    /// `name` is the entry inside `dirPath`; the birth time costs one `fstatat` and only for such rare entries.
    /// Strict mode stops looking once `maxUnattributedPaths` are known (the update fails anyway); tolerant mode
    /// keeps going so that every such file's `alloc` is in `unattributedAlloc`, but keeps only the first paths.
    func vet(_ inode: UInt64, alloc: Int64, dirPath: String, name: UnsafePointer<CChar>?) {
        guard let cutoff = birthCutoff, let name else { return }
        lock.lock()
        let skip = table[inode] != nil || unattributedInodes.contains(inode)
            || (strict && unattributedPaths.count >= maxUnattributedPaths)
        lock.unlock()
        if skip { return }
        var st = stat()
        let path = (dirPath == "/" ? "" : dirPath) + "/" + String(cString: name)
        guard fstatat(AT_FDCWD, path, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        let born = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
        if born < cutoff {
            lock.lock()
            if unattributedInodes.insert(inode).inserted {
                unattributed = true
                unattributedAlloc += alloc
                if unattributedPaths.count < maxUnattributedPaths { unattributedPaths.append(path) }
            }
            lock.unlock()
        }
    }

    /// Drops every link recorded in a directory for which `shouldForget` is true (it is about to be re-read or is gone).
    /// An inode whose owner is dropped is left ownerless; `resolveOrphans` settles it after the re-read.
    /// Entries are changed in place; only the ones that lose their last link are removed.
    func forget(where shouldForget: (Int32) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        var orphaned = false
        var gone: [UInt64] = []
        var i = table.startIndex
        while i != table.endIndex {
            let owner = table.values[i].owner
            if owner >= 0 && shouldForget(owner) { table.values[i].owner = -1 }
            if !table.values[i].others.isEmpty && table.values[i].others.contains(where: shouldForget) {
                table.values[i].others.removeAll(where: shouldForget)
            }
            if table.values[i].owner < 0 {
                if table.values[i].others.isEmpty { gone.append(table.keys[i]) } else { orphaned = true }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table.removeValue(forKey: k) }
        hasOrphans = hasOrphans || orphaned
    }

    /// Gives every ownerless inode to another live directory that still links it, or drops it if none is left.
    /// Returns the sizes each new owner must now count.
    func resolveOrphans() -> [(dir: Int32, alloc: Int64, logical: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard hasOrphans else { return [] }
        hasOrphans = false
        var moved: [(dir: Int32, alloc: Int64, logical: Int64)] = []
        var gone: [UInt64] = []
        var i = table.startIndex
        while i != table.endIndex {
            if table.values[i].owner < 0 {
                if let next = table.values[i].others.first {
                    table.values[i].others.removeFirst()
                    table.values[i].owner = next
                    moved.append((next, table.values[i].alloc, table.values[i].logical))
                } else {
                    gone.append(table.keys[i])
                }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table[k] = nil }
        return moved
    }

    /// Renumbers directories after `DiskTree.compact`; `map[old]` is the new id, or -1 for a dropped directory.
    /// Updates entries in place instead of rebuilding the table.
    func remap(_ map: [Int32]) {
        lock.lock()
        defer { lock.unlock() }
        var gone: [UInt64] = []
        var i = table.startIndex
        while i != table.endIndex {
            let owner = table.values[i].owner
            if owner < 0 || map[Int(owner)] < 0 {
                gone.append(table.keys[i])
            } else {
                table.values[i].owner = map[Int(owner)]
                if !table.values[i].others.isEmpty {
                    table.values[i].others = table.values[i].others.compactMap { map[Int($0)] >= 0 ? map[Int($0)] : nil }
                }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table.removeValue(forKey: k) }
    }
}

/// The whole scanned hierarchy for one root, kept as a flat array of directories.
public final class DiskTree: @unchecked Sendable {
    public let rootPath: String
    public internal(set) var rootDev: dev_t
    public let privateSize: Bool
    /// Only appended to, marked dead, or replaced by `compact` (which resets `links`).
    public internal(set) var nodes: [DirNode]
    /// FSEvents id captured *before* the scan started; replaying from here never misses a change.
    public internal(set) var eventId: UInt64
    public internal(set) var volumeUUID: String
    /// Wall-clock start (ns since epoch) of the scan or update this tree reflects; see `HardlinkRegistry.unattributed`.
    public internal(set) var scanStart: Int64
    public internal(set) var stats = ScanStats()
    /// On-disk bytes that may be counted twice: multiply-linked files older than the tree that an incremental
    /// update met without a record (counted where met; another link may still count them as single-link files).
    /// Grows with tolerant updates, kept in the snapshot, 0 after a full scan.
    public internal(set) var uncertainBytes: Int64 = 0
    let hardlinks: HardlinkRegistry
    fileprivate let links = ChildLinks()

    init(rootPath: String, rootDev: dev_t, privateSize: Bool, nodes: [DirNode],
         eventId: UInt64, volumeUUID: String, scanStart: Int64, hardlinks: HardlinkRegistry) {
        self.rootPath = rootPath
        self.rootDev = rootDev
        self.privateSize = privateSize
        self.nodes = nodes
        self.eventId = eventId
        self.volumeUUID = volumeUUID
        self.scanStart = scanStart
        self.hardlinks = hardlinks
    }

    public var root: DirNode { nodes[0] }

    public func path(of id: Int) -> String {
        var parts: [String] = []
        var i = id
        while i > 0 {
            parts.append(nodes[i].name)
            i = Int(nodes[i].parent)
        }
        let base = rootPath == "/" ? "" : rootPath
        return parts.isEmpty ? rootPath : base + "/" + parts.reversed().joined(separator: "/")
    }

    public func computeTotals() {
        // One buffer access instead of a checked class-property access per field.
        nodes.withUnsafeMutableBufferPointer { nodes in
            for i in nodes.indices {
                nodes[i].totalAlloc = nodes[i].ownAlloc
                nodes[i].totalLogical = nodes[i].ownLogical
                nodes[i].totalFiles = nodes[i].ownFiles
                nodes[i].totalDirs = 0
            }
            for i in nodes.indices.dropFirst().reversed() where !nodes[i].isDead {
                let p = Int(nodes[i].parent)
                nodes[p].totalAlloc += nodes[i].totalAlloc
                nodes[p].totalLogical += nodes[i].totalLogical
                nodes[p].totalFiles += nodes[i].totalFiles
                nodes[p].totalDirs += nodes[i].totalDirs + 1
            }
        }
    }

    /// Recomputes totals only where they can have changed, given that they were correct before the change:
    /// every node from `firstNew` on (appended since), and every node in `changed` (own sizes or set of children
    /// changed) together with all its ancestors. Children always have larger ids, so one descending pass suffices.
    func updateTotals(changed: some Sequence<Int32>, firstNew: Int) {
        syncLinks()
        var dirty = Set<Int32>()
        func mark(_ id: Int32) {
            var i = id
            while i >= 0 && Int(i) < firstNew && dirty.insert(i).inserted {
                i = nodes[Int(i)].parent
            }
        }
        for id in changed where id >= 0 && Int(id) < nodes.count && !nodes[Int(id)].isDead { mark(id) }
        for i in firstNew..<nodes.count where !nodes[i].isDead {
            let p = nodes[i].parent
            if Int(p) < firstNew { mark(p) }
        }
        let first = links.first, next = links.next
        func recompute(_ id: Int) {
            var n = nodes[id]
            n.totalAlloc = n.ownAlloc
            n.totalLogical = n.ownLogical
            n.totalFiles = n.ownFiles
            n.totalDirs = 0
            var c = first[id]
            while c >= 0 {
                let child = nodes[Int(c)]
                if child.parent == Int32(id) {
                    n.totalAlloc += child.totalAlloc
                    n.totalLogical += child.totalLogical
                    n.totalFiles += child.totalFiles
                    n.totalDirs += child.totalDirs + 1
                }
                c = next[Int(c)]
            }
            nodes[id].totalAlloc = n.totalAlloc
            nodes[id].totalLogical = n.totalLogical
            nodes[id].totalFiles = n.totalFiles
            nodes[id].totalDirs = n.totalDirs
        }
        for i in (firstNew..<nodes.count).reversed() where !nodes[i].isDead { recompute(i) }
        for id in dirty.sorted(by: >) where !nodes[Int(id)].isDead { recompute(Int(id)) }
    }

    /// Drops dead nodes in place. A stable compaction keeps the parent-before-child invariant.
    func compact() {
        guard let firstDead = nodes.firstIndex(where: \.isDead) else { return }
        var map = [Int32](repeating: -1, count: nodes.count)
        for i in 0..<firstDead { map[i] = Int32(i) }
        var kept = firstDead
        nodes.withUnsafeMutableBufferPointer { buf in
            for i in firstDead..<buf.count where !buf[i].isDead {
                // A live node's parent is live and has a smaller id, so it is already renumbered.
                map[i] = Int32(kept)
                buf[i].parent = map[Int(buf[i].parent)]
                buf.swapAt(kept, i)
                kept += 1
            }
        }
        nodes.removeSubrange(kept...)
        links.reset()
        hardlinks.remap(map)
    }
}

// MARK: - Child links

/// First-child / next-sibling lists over `nodes`, kept across updates: appended nodes are linked by `syncLinks`,
/// dead nodes stay in their old parent's list and are skipped (their `parent` no longer matches).
/// Built in one pass without hashing; rebuilt only after `compact` renumbers the nodes.
fileprivate final class ChildLinks: @unchecked Sendable {
    let lock = NSLock()
    var first: [Int32] = []
    var next: [Int32] = []

    func reset() {
        lock.lock()
        first = []
        next = []
        lock.unlock()
    }
}

extension DiskTree {
    /// Links every node appended since the last call. Must not run concurrently with a mutation of `nodes`.
    func syncLinks() {
        links.lock.lock()
        defer { links.lock.unlock() }
        syncLinksLocked()
    }

    private func syncLinksLocked() {
        let start = links.first.count
        guard start < nodes.count else { return }
        links.first.append(contentsOf: repeatElement(-1, count: nodes.count - start))
        links.next.append(contentsOf: repeatElement(-1, count: nodes.count - start))
        nodes.withUnsafeBufferPointer { buf in
            links.first.withUnsafeMutableBufferPointer { first in
                links.next.withUnsafeMutableBufferPointer { next in
                    for i in max(start, 1)..<buf.count {
                        let p = Int(buf[i].parent)
                        guard p >= 0 else { continue }
                        next[i] = first[p]
                        first[p] = Int32(i)
                    }
                }
            }
        }
    }

    /// Calls `body` with every live child of `id`. Requires `syncLinks` since the last append.
    func forEachChild(of id: Int32, _ body: (Int32) -> Void) {
        var c = links.first[Int(id)]
        while c >= 0 {
            if nodes[Int(c)].parent == id { body(c) }
            c = links.next[Int(c)]
        }
    }

    /// The live child of `id` called `name`. Requires `syncLinks` since the last append.
    func child(of id: Int32, named name: String) -> Int32? {
        var c = links.first[Int(id)]
        while c >= 0 {
            let n = nodes[Int(c)]
            if n.parent == id && n.name == name { return c }
            c = links.next[Int(c)]
        }
        return nil
    }

    /// Node id of the directory at `path` (absolute, inside `rootPath`), or nil when it is not in the tree.
    public func node(at path: String) -> Int? {
        let base = rootPath == "/" ? "" : rootPath
        if path == rootPath { return 0 }
        guard path.hasPrefix(base + "/") else { return nil }
        let comps = path.dropFirst(base.count + 1).split(separator: "/")

        links.lock.lock()
        defer { links.lock.unlock() }
        syncLinksLocked()
        var cur: Int32 = 0
        for c in comps {
            guard let n = child(of: cur, named: String(c)) else { return nil }
            cur = n
        }
        return Int(cur)
    }
}
