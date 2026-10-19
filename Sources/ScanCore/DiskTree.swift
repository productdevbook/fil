import Darwin
import Foundation
import Synchronization

/// One record per scanned directory. Files are not stored individually; they roll up into their directory.
/// Invariant: a child always has a larger id than its parent, so totals are one reverse pass.
public struct DirNode: Sendable {
    public static let dead: Int32 = -2

    public var parent: Int32
    /// The directory exists but could not be listed (permissions); it then has no own sizes and no children,
    /// like in a full scan. Stored right after `parent`, in its padding.
    public var unreadable = false
    /// Listed only in part (a `getattrlistbulk` failure mid-directory or an entry error): its own sizes are a lower
    /// bound and a child directory may be missing. In the padding after `unreadable`.
    public var incomplete = false
    public var name: String
    /// Files directly inside this directory only.
    public var ownAlloc: Int64 = 0
    public var ownLogical: Int64 = 0
    public var ownFiles: Int64 = 0
    /// Clone-aware allocated bytes: like `ownAlloc` (always from ATTR_FILE_ALLOCSIZE, also with `privateSize`), but
    /// each APFS full-clone family is counted once, in the directory that owns it (`CloneRegistry`).
    public var ownCloneAware: Int64 = 0
    /// Including subdirectories (filled by `computeTotals`).
    public var totalAlloc: Int64 = 0
    public var totalLogical: Int64 = 0
    public var totalFiles: Int64 = 0
    public var totalDirs: Int64 = 0
    public var totalCloneAware: Int64 = 0
    /// The directory's identity: `ATTR_CMN_FILEID` from the listing that found it (the root: `st_ino`). An update tells
    /// a folder deleted and recreated under the same name from the old one by it. 0 = unknown, never compared.
    /// At offset 96; the stride is 104 bytes.
    public var fileID: UInt64 = 0

    public var isDead: Bool { parent == DirNode.dead }
}

public struct ScanOptions: Sendable {
    public var threads: Int
    #if DEBUG
        /// Test-only faults injected into every directory read; compiled out of release builds.
        var faults = DirFaults.environment
    #endif
    /// For APFS clones, count only blocks private to this file (ATTR_CMNEXT_PRIVATESIZE).
    public var privateSize: Bool
    public var crossDevices: Bool
    /// Incremental updates: a multiply-linked file older than the tree and unknown to it fails the update
    /// (strict), or is counted where it was found and added to `DiskTree.uncertainBytes` (tolerant).
    public var strictHardlinks: Bool
    /// Firmlinks of the volume group; a scan that covers both a firmlink and its data-volume directory
    /// descends only through the firmlink. Injectable for tests.
    public var firmlinks: FirmlinkTable

    // Measured on M-series + APFS: throughput plateaus around 8 threads (kernel-bound beyond that).
    public init(
        threads: Int = 8, privateSize: Bool = false, crossDevices: Bool = false, strictHardlinks: Bool = true,
        firmlinks: FirmlinkTable = .system
    ) {
        self.threads = max(1, threads)
        self.strictHardlinks = strictHardlinks
        self.privateSize = privateSize
        self.crossDevices = crossDevices
        self.firmlinks = firmlinks
    }
}

public struct ScanStats: Sendable {
    public var openErrors = 0  // directories that could not be opened (mostly TCC / permissions)
    public var entryErrors = 0
    public var hardlinkDupes = 0  // hard links not counted twice
    public var datalessDirs = 0  // iCloud/Dropbox placeholder dirs — never downloaded or entered
    public var datalessLogical: Int64 = 0
    public var mountsSkipped = 0
    /// Data-volume directories not entered because the scan reaches them through their firmlink.
    public var firmlinksSkipped = 0
    /// Full-clone files whose blocks were already counted for another member of their clone family.
    public var cloneDupes = 0

    public init() {}

    /// The fields in the order of `merge`, as stored in the snapshot's stats section.
    var stored: [Int64] {
        [
            Int64(openErrors), Int64(entryErrors), Int64(hardlinkDupes), Int64(datalessDirs), datalessLogical,
            Int64(mountsSkipped), Int64(firmlinksSkipped), Int64(cloneDupes),
        ]
    }

    /// The inverse of `stored`; `v` holds 8 values.
    init(stored v: [Int64]) {
        openErrors = Int(v[0])
        entryErrors = Int(v[1])
        hardlinkDupes = Int(v[2])
        datalessDirs = Int(v[3])
        datalessLogical = v[4]
        mountsSkipped = Int(v[5])
        firmlinksSkipped = Int(v[6])
        cloneDupes = Int(v[7])
    }

    mutating func merge(_ o: ScanStats) {
        openErrors += o.openErrors
        entryErrors += o.entryErrors
        hardlinkDupes += o.hardlinkDupes
        datalessDirs += o.datalessDirs
        datalessLogical += o.datalessLogical
        mountsSkipped += o.mountsSkipped
        firmlinksSkipped += o.firmlinksSkipped
        cloneDupes += o.cloneDupes
    }
}

/// A registry's keys by directory, so that `forget` finds what a directory holds without walking the table.
/// Built in two passes over the table into one flat array grouped by directory id (a counting sort: no hashing and one
/// allocation per array, not one per directory); keys recorded later go to a small dictionary. Stale and repeated
/// keys are allowed: the registry checks an entry before it changes it.
struct RegistryIndex {
    /// The keys of directory `d` are `keys[start[d]..<start[d + 1]]` for `d < start.count - 1`.
    private var start: [Int32] = [0]
    private var keys: [UInt64] = []
    /// Keys recorded since the build, and every key of a directory created since.
    private var added: [Int32: [UInt64]] = [:]

    /// `pairs` calls its argument once per (directory, key) of the table, the same pairs in the same order each time.
    init(_ pairs: ((Int32, UInt64) -> Void) -> Void) {
        var count: [Int32] = []
        var total = 0
        pairs { d, _ in
            let d = Int(d)
            if d >= count.count { count.append(contentsOf: repeatElement(0, count: d + 1 - count.count)) }
            count[d] += 1
            total += 1
        }
        var start = [Int32](repeating: 0, count: count.count + 1)
        for d in count.indices { start[d + 1] = start[d] + count[d] }
        var fill = start
        var keys = [UInt64](repeating: 0, count: total)
        keys.withUnsafeMutableBufferPointer { out in
            pairs { d, k in
                out[Int(fill[Int(d)])] = k
                fill[Int(d)] += 1
            }
        }
        self.start = start
        self.keys = keys
    }

    /// From (directory, key) pairs collected while the table was decoded (`Snapshot.load`).
    init(pairs: [(dir: Int32, key: UInt64)]) {
        self.init { visit in for p in pairs { visit(p.dir, p.key) } }
    }

    mutating func add(_ key: UInt64, to dir: Int32) { added[dir, default: []].append(key) }

    /// Calls `body` with every key recorded for `dir`, and drops the ones recorded since the build. The built ones stay
    /// (they are only read): a later call for `dir` meets them again, as stale keys.
    mutating func take(_ dir: Int32, _ body: (UInt64) -> Void) {
        if Int(dir) + 1 < start.count {
            for k in keys[Int(start[Int(dir)])..<Int(start[Int(dir) + 1])] { body(k) }
        }
        if let more = added.removeValue(forKey: dir) { more.forEach(body) }
    }
}

/// The multiply-linked files of one directory listing, claimed or vetted by `HardlinkRegistry` under one lock
/// acquisition (chapter 01 §4.4). One per worker, emptied for each directory with its capacity kept: once its arrays
/// have grown, collecting a link allocates nothing.
struct LinkBatch {
    struct Link {
        var inode: UInt64
        var alloc: Int64
        var logical: Int64
        var cloneAware: Int64
        /// Offset of the entry's NUL-terminated name in `names`; -1 when names are not kept.
        var name: Int32
    }

    private(set) var links: [Link] = []
    /// Names are needed only to vet links during an update (a birth-time `fstatat`); a full scan copies none.
    let keepNames: Bool
    private var names: [CChar] = []
    /// Scratch for the registry: indices into `links` whose birth time `vet` must check.
    var suspects: [Int32] = []

    init(keepNames: Bool) { self.keepNames = keepNames }

    mutating func reset() {
        links.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    mutating func append(
        _ inode: UInt64, alloc: Int64, logical: Int64, cloneAware: Int64, name: UnsafePointer<CChar>?
    ) {
        var offset: Int32 = -1
        if keepNames, let name {
            offset = Int32(names.count)
            names.append(contentsOf: UnsafeBufferPointer(start: name, count: strlen(name) + 1))
        }
        links.append(Link(inode: inode, alloc: alloc, logical: logical, cloneAware: cloneAware, name: offset))
    }

    func name(at offset: Int32) -> String {
        names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + Int(offset)) }
    }
}

/// What the counted links of a `LinkBatch` add to their directory; `dupes` were counted elsewhere.
struct LinkTotals: Equatable {
    var alloc: Int64 = 0
    var logical: Int64 = 0
    var cloneAware: Int64 = 0
    var files: Int64 = 0
    var dupes = 0
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
        /// Allocated size counted in `ownCloneAware` (hard-linked files are never deduplicated as clones).
        var cloneAware: Int64
        /// Other directories where a link was seen (never contains `owner`).
        var others: [Int32] = []
    }

    private let lock = NSLock()
    #if DEBUG
        /// Lock acquisitions so far, for tests of the per-directory budget. Not compiled into release builds.
        let debugLockCount = Atomic<Int>(0)
    #endif
    private(set) var table: [UInt64: Entry]
    /// Per directory, the inodes it owns or links (`owner` or `others`), so that `forget` touches only the directories
    /// it is given. Nil until `buildIndex` (a full scan never forgets, so it never pays for it); then kept up to date.
    /// Stale or repeated keys are allowed and skipped on use: an entry is checked before it is changed.
    private var byDir: RegistryIndex?
    /// Ownerless inodes that still have links elsewhere; `resolveOrphans` settles them.
    private var orphans = Set<UInt64>()
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
    private var drift: [Int32: (alloc: Int64, logical: Int64, cloneAware: Int64)]?

    init(_ table: [UInt64: Entry] = [:], index: RegistryIndex? = nil) {
        self.table = table
        byDir = index
    }

    /// Takes the lock; every acquisition goes through here (counted in debug builds).
    @inline(__always)
    private func acquire() {
        lock.lock()
        #if DEBUG
            debugLockCount.wrappingAdd(1, ordering: .relaxed)
        #endif
    }

    /// Builds the per-directory index from the table, O(table). `Snapshot.load` hands the registry an index made while
    /// decoding instead; a tree scanned in this process gets one on its first `forget`.
    func buildIndex() {
        acquire()
        defer { lock.unlock() }
        buildIndexLocked()
    }

    private func buildIndexLocked() {
        byDir = RegistryIndex { visit in
            for (inode, e) in table {
                if e.owner >= 0 { visit(e.owner, inode) }
                for d in e.others { visit(d, inode) }
            }
        }
    }

    /// Claims every link of `batch`, all listed in `dir` (at `dirPath`), under one lock acquisition: per link, in
    /// listing order, the same decision as `claimLocked`. During an update each link is first vetted as `vet` does.
    /// Returns what the counted links add to `dir`; the others are `dupes`.
    func claim(_ batch: inout LinkBatch, by dir: Int32, dirPath: String) -> LinkTotals {
        var totals = LinkTotals()
        guard !batch.links.isEmpty else { return totals }
        batch.suspects.removeAll(keepingCapacity: true)
        let vetting = birthCutoff != nil
        acquire()
        for k in batch.links.indices {
            let l = batch.links[k]
            if vetting && l.name >= 0 && isSuspectLocked(l.inode) { batch.suspects.append(Int32(k)) }
            if claimLocked(l.inode, by: dir, alloc: l.alloc, logical: l.logical, cloneAware: l.cloneAware) {
                totals.alloc += l.alloc
                totals.logical += l.logical
                totals.cloneAware += l.cloneAware
                totals.files += 1
            } else {
                totals.dupes += 1
            }
        }
        lock.unlock()
        if !batch.suspects.isEmpty { vetSuspects(batch, dirPath: dirPath) }
        return totals
    }

    /// Claims the links an update deferred (`DirOutcome.deferredLinks`), each in its own directory, under one lock
    /// acquisition. `result[k]` is true when `links[k].dir` counts the size.
    func claim(_ links: [(dir: Int32, inode: UInt64, alloc: Int64, logical: Int64, cloneAware: Int64)]) -> [Bool] {
        guard !links.isEmpty else { return [] }
        acquire()
        defer { lock.unlock() }
        return links.map {
            claimLocked($0.inode, by: $0.dir, alloc: $0.alloc, logical: $0.logical, cloneAware: $0.cloneAware)
        }
    }

    /// One link, under its own lock acquisition (tests). Scans and updates claim batches.
    func claim(_ inode: UInt64, by dir: Int32, alloc: Int64, logical: Int64, cloneAware: Int64) -> Bool {
        acquire()
        defer { lock.unlock() }
        return claimLocked(inode, by: dir, alloc: alloc, logical: logical, cloneAware: cloneAware)
    }

    /// Records a link to `inode` seen in `dir`. True if `dir` should count the size (it is, or just became, the owner).
    /// Lock held.
    @inline(__always)
    private func claimLocked(_ inode: UInt64, by dir: Int32, alloc: Int64, logical: Int64, cloneAware: Int64) -> Bool {
        guard let i = table.index(forKey: inode) else {
            table[inode] = Entry(owner: dir, alloc: alloc, logical: logical, cloneAware: cloneAware)
            byDir?.add(inode, to: dir)
            return true
        }
        let owner = table.values[i].owner
        if owner == dir { return false }
        if owner < 0 {
            table.values[i].owner = dir
            table.values[i].alloc = alloc
            table.values[i].logical = logical
            table.values[i].cloneAware = cloneAware
            if !table.values[i].others.isEmpty { table.values[i].others.removeAll { $0 == dir } }
            byDir?.add(inode, to: dir)
            orphans.remove(inode)
            return true
        }
        if !table.values[i].others.contains(dir) {
            table.values[i].others.append(dir)
            byDir?.add(inode, to: dir)
        }
        // Sizes differ only when the file changed since the owner counted it (incremental updates).
        let e = table.values[i]
        if e.alloc != alloc || e.logical != logical || e.cloneAware != cloneAware {
            drift?[owner, default: (0, 0, 0)].alloc += alloc - e.alloc
            drift?[owner, default: (0, 0, 0)].logical += logical - e.logical
            drift?[owner, default: (0, 0, 0)].cloneAware += cloneAware - e.cloneAware
            table.values[i].alloc = alloc
            table.values[i].logical = logical
            table.values[i].cloneAware = cloneAware
        }
        return false
    }

    /// Incremental only: starts recording size changes seen through a link outside the owning directory.
    func trackDrift() {
        acquire()
        drift = [:]
        lock.unlock()
    }

    /// Returns, per owner directory, how much its counted size must change, and stops recording.
    func takeDrift() -> [Int32: (alloc: Int64, logical: Int64, cloneAware: Int64)] {
        acquire()
        defer { lock.unlock() }
        let out = drift ?? [:]
        drift = nil
        return out
    }

    /// Starts an incremental update of a tree scanned at `cutoff`; clears what the previous update found.
    func beginUpdate(cutoff: Int64, strict: Bool) {
        acquire()
        birthCutoff = cutoff
        self.strict = strict
        unattributed = false
        unattributedPaths = []
        unattributedInodes = []
        unattributedAlloc = 0
        lock.unlock()
    }

    func endUpdate() {
        acquire()
        birthCutoff = nil
        unattributedInodes = []
        lock.unlock()
    }

    /// Incremental only: flags the multiply-linked files of `batch` (listed in `dirPath`) that predate the snapshot but
    /// have no record. One lock acquisition looks them all up; only the unknown ones cost an `fstatat` for their birth
    /// time (`vetSuspects`). Strict mode stops looking once `maxUnattributedPaths` are known (the update fails anyway);
    /// tolerant mode keeps going so that every such file's `alloc` is in `unattributedAlloc`, but keeps only the first
    /// paths.
    func vet(_ batch: inout LinkBatch, dirPath: String) {
        guard birthCutoff != nil, !batch.links.isEmpty else { return }
        batch.suspects.removeAll(keepingCapacity: true)
        acquire()
        for k in batch.links.indices where batch.links[k].name >= 0 && isSuspectLocked(batch.links[k].inode) {
            batch.suspects.append(Int32(k))
        }
        lock.unlock()
        if !batch.suspects.isEmpty { vetSuspects(batch, dirPath: dirPath) }
    }

    /// An update met `inode`: it has no record and is not yet known to be unattributed. Lock held.
    @inline(__always)
    private func isSuspectLocked(_ inode: UInt64) -> Bool {
        table[inode] == nil && !unattributedInodes.contains(inode)
            && !(strict && unattributedPaths.count >= maxUnattributedPaths)
    }

    /// Checks the birth time of `batch.suspects` (one `fstatat` each, without the lock) and records those born before
    /// `birthCutoff`. Only then is the lock taken a second time for the directory: an unattributed hard link was met.
    private func vetSuspects(_ batch: LinkBatch, dirPath: String) {
        guard let cutoff = birthCutoff else { return }
        var found: [(inode: UInt64, alloc: Int64, path: String)] = []
        for k in batch.suspects {
            let l = batch.links[Int(k)]
            var st = stat()
            let path = (dirPath == "/" ? "" : dirPath) + "/" + batch.name(at: l.name)
            guard fstatat(AT_FDCWD, path, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let born = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
            if born < cutoff { found.append((l.inode, l.alloc, path)) }
        }
        guard !found.isEmpty else { return }
        acquire()
        for f in found where unattributedInodes.insert(f.inode).inserted {
            unattributed = true
            unattributedAlloc += f.alloc
            if unattributedPaths.count < maxUnattributedPaths { unattributedPaths.append(f.path) }
        }
        lock.unlock()
    }

    /// Drops every link recorded in `dirs` (each is about to be re-read or is gone). Touches only the entries those
    /// directories hold (`byDir`), not the table. An inode whose owner is dropped is left ownerless; `resolveOrphans`
    /// settles it after the re-read. Entries are changed in place; only the ones that lose their last link are removed.
    func forget(_ dirs: Set<Int32>) {
        guard !dirs.isEmpty else { return }
        acquire()
        defer { lock.unlock() }
        if byDir == nil { buildIndexLocked() }
        for d in dirs {
            byDir?.take(d) { inode in
                guard let i = table.index(forKey: inode) else { return }
                if table.values[i].owner == d {
                    table.values[i].owner = -1
                } else if let k = table.values[i].others.firstIndex(of: d) {
                    table.values[i].others.remove(at: k)
                } else {
                    return  // stale or repeated key
                }
                guard table.values[i].owner < 0 else { return }
                if table.values[i].others.isEmpty {
                    table.remove(at: i)
                    orphans.remove(inode)
                } else {
                    orphans.insert(inode)
                }
            }
        }
    }

    /// Gives every ownerless inode to another live directory that still links it, or drops it if none is left.
    /// Returns the sizes each new owner must now count. Walks only the orphans, not the table.
    func resolveOrphans() -> [(dir: Int32, alloc: Int64, logical: Int64, cloneAware: Int64)] {
        acquire()
        defer { lock.unlock() }
        guard !orphans.isEmpty else { return [] }
        var moved: [(dir: Int32, alloc: Int64, logical: Int64, cloneAware: Int64)] = []
        // In inode order: the result does not depend on the set's iteration order.
        for inode in orphans.sorted() {
            guard let i = table.index(forKey: inode), table.values[i].owner < 0 else { continue }
            if let next = table.values[i].others.first {
                // `next` keeps its index key: it moves from `others` to `owner`.
                table.values[i].others.removeFirst()
                table.values[i].owner = next
                let e = table.values[i]
                moved.append((next, e.alloc, e.logical, e.cloneAware))
            } else {
                table.remove(at: i)
            }
        }
        orphans.removeAll()
        return moved
    }

    /// Renumbers directories after `DiskTree.compact`; `map[old]` is the new id, or -1 for a dropped directory.
    /// Updates entries in place instead of rebuilding the table.
    func remap(_ map: [Int32]) {
        acquire()
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
                    table.values[i].others = table.values[i].others.compactMap {
                        map[Int($0)] >= 0 ? map[Int($0)] : nil
                    }
                }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table.removeValue(forKey: k) }
        // Every ownerless entry was dropped above. The index is O(table) to renumber, like the table: rebuilt.
        orphans.removeAll()
        if byDir != nil { buildIndexLocked() }
    }
}

/// A directory of the tree on which another volume was mounted when it was last listed: the scan left it out
/// (never crossing into another device). Kept so that an update can find it again once the volume is unmounted,
/// which leaves no FSEvents event.
public struct MountPoint: Hashable, Sendable {
    /// Directory that lists the mount point.
    public var parent: Int32
    public var name: String

    public init(parent: Int32, name: String) {
        self.parent = parent
        self.name = name
    }
}

/// The whole scanned hierarchy for one root, kept as a flat array of directories.
///
/// Concurrent access (chapter 01 §5.6): a tree passed to `Incremental.update` or `Snapshot.save` is owned by that call
/// until it returns, and nothing else may read or change it meanwhile. A reader that must not wait takes
/// `let view = tree.nodes` before the call (copy-on-write: a consistent copy at no cost) and labels it last-known.
/// A second `update` or `save` of the same tree while one runs is a `preconditionFailure`. A full scan builds its tree
/// privately and publishes it only when `Scanner.scan` returns.
public final class DiskTree: @unchecked Sendable {
    public let rootPath: String
    public internal(set) var rootDev: dev_t
    public let privateSize: Bool
    /// Scanned with `ScanOptions.crossDevices`: other volumes mounted inside the root are counted.
    public let crossDevices: Bool
    /// Only appended to, marked dead, or replaced by `compact` (which resets `links`).
    public internal(set) var nodes: [DirNode]
    /// FSEvents id captured *before* the scan started; replaying from here never misses a change.
    public internal(set) var eventId: UInt64
    public internal(set) var volumeUUID: String
    /// Wall-clock start (ns since epoch) of the scan or update this tree reflects; see `HardlinkRegistry.unattributed`.
    public internal(set) var scanStart: Int64
    /// Counters of the last full scan (`fullScanStart`). An update leaves them unchanged: they are totals, which a
    /// re-read cannot correct (its own counts are in `UpdateReport.stats`). Kept in the snapshot.
    public internal(set) var stats = ScanStats()
    /// Wall-clock start (ns since epoch) of the full scan `stats` come from; nil when they are unknown (a snapshot
    /// written without them), in which case `stats` are zero and must not be shown.
    public internal(set) var fullScanStart: Int64?
    /// On-disk bytes that may be counted twice: multiply-linked files older than the tree that an incremental
    /// update met without a record (counted where met; another link may still count them as single-link files).
    /// Grows with tolerant updates, kept in the snapshot, 0 after a full scan.
    public internal(set) var uncertainBytes: Int64 = 0
    /// Data-volume directories this tree reaches through a firmlink instead (`FirmlinkTable.aliases(for:)`).
    public let aliases: [FirmlinkTable.Alias]
    /// Mount points the scan skipped inside the root, each under a live directory (none with `crossDevices`).
    /// Refreshed whenever their parent is listed again; compared with the mount table on every update.
    public internal(set) var mountPoints: [MountPoint] = []
    /// Raw bytes of the directory names that are not valid UTF-8; `DirNode.name` then holds a display form with
    /// U+FFFD, which no syscall can open. Rare: empty for most trees.
    public internal(set) var rawNames: [Int32: [UInt8]] = [:]
    /// Live folders flagged `incomplete`, which every update reads again. Nil after a full scan or a load (the next
    /// update finds them with one pass over the nodes); then kept by each update, so that later ones skip the pass.
    var incompleteDirs: [Int32]?
    /// An update changed the tree since it was loaded, scanned or saved: `Snapshot.advance` must not be used.
    var changedSinceSave = false
    let exclusions: [String: Set<String>]
    let hardlinks: HardlinkRegistry
    let clones: CloneRegistry
    fileprivate let links = ChildLinks()
    /// Set while `Incremental.update` or `Snapshot.save` owns the tree.
    private let busy = Mutex(false)

    init(
        rootPath: String, rootDev: dev_t, privateSize: Bool, crossDevices: Bool, nodes: [DirNode],
        eventId: UInt64, volumeUUID: String, scanStart: Int64, hardlinks: HardlinkRegistry,
        clones: CloneRegistry, aliases: [FirmlinkTable.Alias], mountPoints: [MountPoint] = []
    ) {
        self.crossDevices = crossDevices
        self.mountPoints = mountPoints
        self.aliases = aliases
        self.exclusions = aliases.exclusions
        self.clones = clones
        self.rootPath = rootPath
        self.rootDev = rootDev
        self.privateSize = privateSize
        self.nodes = nodes
        self.eventId = eventId
        self.volumeUUID = volumeUUID
        self.scanStart = scanStart
        self.fullScanStart = scanStart
        self.hardlinks = hardlinks
    }

    /// Takes the tree for `caller` (an update or a save) until `release`; traps if another one holds it.
    func acquire(_ caller: StaticString) {
        let wasBusy = busy.withLock { b in
            defer { b = true }
            return b
        }
        if wasBusy { preconditionFailure("\(caller): the tree is already being updated or saved") }
    }

    func release() { busy.withLock { $0 = false } }

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

    /// The path of `id` for a syscall, NUL-terminated, built from `rawNames`; nil when `path(of:)` is exact (no
    /// component on the way to the root has a raw name).
    func cPath(of id: Int) -> [CChar]? {
        guard !rawNames.isEmpty else { return nil }
        var parts: [[UInt8]] = []
        var raw = false
        var i = id
        while i > 0 {
            if let r = rawNames[Int32(i)] {
                parts.append(r)
                raw = true
            } else {
                parts.append(Array(nodes[i].name.utf8))
            }
            i = Int(nodes[i].parent)
        }
        guard raw else { return nil }
        var out = Array((rootPath == "/" ? "" : rootPath).utf8)
        for p in parts.reversed() {
            out.append(UInt8(ascii: "/"))
            out += p
        }
        out.append(0)
        return out.map { CChar(bitPattern: $0) }
    }

    public func computeTotals() {
        // One buffer access instead of a checked class-property access per field.
        nodes.withUnsafeMutableBufferPointer { nodes in
            for i in nodes.indices {
                nodes[i].totalAlloc = nodes[i].ownAlloc
                nodes[i].totalLogical = nodes[i].ownLogical
                nodes[i].totalFiles = nodes[i].ownFiles
                nodes[i].totalCloneAware = nodes[i].ownCloneAware
                nodes[i].totalDirs = 0
            }
            for i in nodes.indices.dropFirst().reversed() where !nodes[i].isDead {
                let p = Int(nodes[i].parent)
                nodes[p].totalAlloc += nodes[i].totalAlloc
                nodes[p].totalLogical += nodes[i].totalLogical
                nodes[p].totalFiles += nodes[i].totalFiles
                nodes[p].totalCloneAware += nodes[i].totalCloneAware
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
            n.totalCloneAware = n.ownCloneAware
            n.totalDirs = 0
            var c = first[id]
            while c >= 0 {
                let child = nodes[Int(c)]
                if child.parent == Int32(id) {
                    n.totalAlloc += child.totalAlloc
                    n.totalLogical += child.totalLogical
                    n.totalFiles += child.totalFiles
                    n.totalCloneAware += child.totalCloneAware
                    n.totalDirs += child.totalDirs + 1
                }
                c = next[Int(c)]
            }
            nodes[id].totalAlloc = n.totalAlloc
            nodes[id].totalLogical = n.totalLogical
            nodes[id].totalFiles = n.totalFiles
            nodes[id].totalCloneAware = n.totalCloneAware
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
        clones.remap(map)
        mountPoints = mountPoints.compactMap { m in
            map[Int(m.parent)] < 0 ? nil : MountPoint(parent: map[Int(m.parent)], name: m.name)
        }
        incompleteDirs = incompleteDirs?.compactMap { map[Int($0)] < 0 ? nil : map[Int($0)] }
        if !rawNames.isEmpty {
            rawNames = Dictionary(
                uniqueKeysWithValues: rawNames.compactMap { id, bytes in
                    map[Int(id)] < 0 ? nil : (map[Int(id)], bytes)
                })
        }
    }
}

// MARK: - Child links

/// First-child / next-sibling lists over `nodes`, kept across updates: appended nodes are linked by `syncLinks`,
/// dead nodes stay in their old parent's list and are skipped (their `parent` no longer matches).
/// Built in one pass without hashing; rebuilt only after `compact` renumbers the nodes.
/// A child's id is larger than every id appended before it, so each list runs from the newest child to the oldest.
fileprivate final class ChildLinks: @unchecked Sendable {
    let lock = NSLock()
    var first: [Int32] = []
    var next: [Int32] = []
    /// Name indexes of the directories in which a lookup walked more than `DiskTree.nameIndexThreshold` siblings.
    var names: [Int32: NameIndex] = [:]

    func reset() {
        lock.lock()
        first = []
        next = []
        names = [:]
        lock.unlock()
    }
}

/// The children of one directory by name: open addressing with linear probing over child ids. The hash is Swift's
/// `String` hash, which canonically equivalent spellings (NFC and NFD `é`) share, so one probe sequence finds both a
/// byte-equal and an equivalent name, and a `Substring` hashes like the `String` it spells: a lookup allocates nothing.
/// Children are only added (by `syncLinks`); a dead one stays until the table is rebuilt, and a lookup skips it because
/// its `parent` no longer matches. Names never change in place: a rename is a dead node plus a new one.
fileprivate struct NameIndex {
    /// Child id per slot, -1 when empty; `hashes` holds its name's hash.
    private(set) var ids: [Int32]
    private(set) var hashes: [Int]
    /// Occupied slots, dead children included.
    private var used = 0

    init(capacityFor count: Int) {
        // At most half full when built; grown (rebuilt) past 3/4.
        var capacity = 64
        while capacity < 2 * count { capacity *= 2 }
        ids = [Int32](repeating: -1, count: capacity)
        hashes = [Int](repeating: 0, count: capacity)
    }

    var isFull: Bool { 4 * used >= 3 * ids.count }

    mutating func insert(_ id: Int32, hash: Int) {
        let mask = ids.count - 1
        var i = hash & mask
        while ids[i] >= 0 { i = (i + 1) & mask }
        ids[i] = id
        hashes[i] = hash
        used += 1
    }

    /// Calls `body` with each child id stored under `hash`.
    func forEach(hash: Int, _ body: (Int32) -> Void) {
        let mask = ids.count - 1
        var i = hash & mask
        while ids[i] >= 0 {
            if hashes[i] == hash { body(ids[i]) }
            i = (i + 1) & mask
        }
    }
}

@inline(__always)
private func nameHash(_ name: some StringProtocol) -> Int {
    var h = Hasher()
    h.combine(name)
    return h.finalize()
}

extension DiskTree {
    /// A lookup that walks more siblings than this builds the directory's name index (`NameIndex`).
    static let nameIndexThreshold = 32

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
        // New children of an indexed directory go into its index (none in most updates: no index exists).
        guard !links.names.isEmpty else { return }
        var rebuilt = Set<Int32>()  // a rebuild takes every child already linked, the ones still to come included
        for i in max(start, 1)..<nodes.count {
            let p = nodes[i].parent
            guard p >= 0, links.names[p] != nil, !rebuilt.contains(p) else { continue }
            if links.names[p]!.isFull {
                buildNameIndex(p)
                rebuilt.insert(p)
            } else {
                links.names[p]!.insert(Int32(i), hash: nameHash(nodes[i].name))
            }
        }
    }

    /// (Re)builds the name index of `id` from its live children.
    private func buildNameIndex(_ id: Int32) {
        var children: [Int32] = []
        forEachChild(of: id) { children.append($0) }
        var index = NameIndex(capacityFor: children.count)
        for c in children { index.insert(c, hash: nameHash(nodes[Int(c)].name)) }
        links.names[id] = index
    }

    /// `id` has a name index (tests).
    func hasNameIndex(of id: Int32) -> Bool { links.names[id] != nil }

    /// Calls `body` with every live child of `id`. Requires `syncLinks` since the last append.
    func forEachChild(of id: Int32, _ body: (Int32) -> Void) {
        var c = links.first[Int(id)]
        while c >= 0 {
            if nodes[Int(c)].parent == id { body(c) }
            c = links.next[Int(c)]
        }
    }

    /// The live child of `id` called `name`. Requires `syncLinks` since the last append.
    /// Names are compared by their UTF-8 bytes first: `String` equality treats NFC and NFD forms as one name, and both
    /// can exist side by side on some volumes. A path from outside the listing (an event, a typed path) may use another
    /// normalization than the disk; when no name matches byte for byte, a canonically equal one is taken. Among several
    /// matches the newest child wins (the first in its list).
    /// A directory with many children gets a name index the first time a lookup walks more than `nameIndexThreshold`
    /// siblings; from then on a lookup there costs one hash of `name` and a short probe. Allocates no `String`.
    func child(of id: Int32, named name: some StringProtocol) -> Int32? {
        if let index = links.names[id] {
            var exact: Int32 = -1
            var equivalent: Int32 = -1
            index.forEach(hash: nameHash(name)) { c in
                guard nodes[Int(c)].parent == id, c > exact else { return }
                if nodes[Int(c)].name.utf8.elementsEqual(name.utf8) {
                    exact = c
                } else if c > equivalent && nodes[Int(c)].name == name {
                    equivalent = c
                }
            }
            return exact >= 0 ? exact : equivalent >= 0 ? equivalent : nil
        }
        var exact: Int32?
        var equivalent: Int32?
        var walked = 0
        var c = links.first[Int(id)]
        while c >= 0 {
            walked += 1
            let n = nodes[Int(c)]
            if n.parent == id {
                if n.name.utf8.elementsEqual(name.utf8) {
                    exact = c
                    break
                }
                if equivalent == nil && n.name == name { equivalent = c }
            }
            c = links.next[Int(c)]
        }
        if walked > Self.nameIndexThreshold { buildNameIndex(id) }
        return exact ?? equivalent
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
            guard let n = child(of: cur, named: c) else { return nil }
            cur = n
        }
        return Int(cur)
    }
}
