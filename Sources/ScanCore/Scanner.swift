import CoreServices
import Darwin
import Foundation
import Synchronization

/// Live counters of a running scan, safe to read from any thread while workers update them.
/// Workers add once per directory read, never per file.
public final class ScanProgress: Sendable {
    public let dirs = Atomic<Int64>(0)
    public let files = Atomic<Int64>(0)
    /// Clone-aware on-disk bytes counted so far (`DirNode.ownCloneAware`).
    public let bytes = Atomic<Int64>(0)

    public init() {}

    @inline(__always)
    func add(files: Int64, bytes: Int64) {
        dirs.wrappingAdd(1, ordering: .relaxed)
        if files != 0 { self.files.wrappingAdd(files, ordering: .relaxed) }
        if bytes != 0 { self.bytes.wrappingAdd(bytes, ordering: .relaxed) }
    }
}

public enum Scanner {
    /// Full parallel scan of `path`. `progress`, when given, is updated live while the scan runs.
    public static func scan(
        _ path: String, options: ScanOptions = ScanOptions(),
        progress: ScanProgress? = nil
    ) throws -> DiskTree {
        preventCloudDownloads()
        var st = stat()
        guard lstat(path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let scanStart = nowNanoseconds()
        // Taken before walking: anything that changes during the scan is replayed next time.
        let eventId = FSEventsGetCurrentEventId()
        let tree = DiskTree(
            rootPath: path, rootDev: st.st_dev, privateSize: options.privateSize,
            crossDevices: options.crossDevices, nodes: [DirNode(parent: -1, name: path, fileID: st.st_ino)],
            eventId: eventId,
            volumeUUID: volumeUUID(st.st_dev), scanStart: scanStart, hardlinks: HardlinkRegistry(),
            clones: CloneRegistry(), aliases: options.firmlinks.aliases(for: path))
        // Laps (FIL_TIMINGS=1) go around whole phases; with timings off no clock is read.
        var t = Timings.enabled ? Timings.Lap("scan") : nil
        _ = rescanSubtrees([0], in: tree, options: options, progress: progress)
        // Folders that vanished during the walk are dead nodes; nothing else may see them.
        tree.compact()
        t?.lap("walk")
        _ = applyPreferredOriginals(tree)
        t?.lap("originals")
        tree.computeTotals()
        t?.lap("totals")
        return tree
    }

    /// Moves each clone family to the directory holding its original (deterministic attribution).
    /// Returns the directories whose own sizes changed.
    static func applyPreferredOriginals(_ tree: DiskTree) -> [Int32] {
        var changed: [Int32] = []
        for m in tree.clones.preferOriginals() {
            tree.nodes[Int(m.from)].ownCloneAware -= m.alloc
            tree.nodes[Int(m.to)].ownCloneAware += m.alloc
            changed.append(m.from)
            changed.append(m.to)
        }
        return changed
    }

    /// Scans the subtrees under existing nodes `ids` in one parallel pass. Their old descendants must
    /// already be dead; new descendants are appended to the tree. Returns the ids whose directory is gone
    /// (`DirOutcome.isGone`) with the errno of the failed `open`; an unreadable root stays, empty, like in a full scan.
    /// Mount points skipped below `ids` are appended to `tree.mountPoints`. A directory below `ids` that vanished between
    /// its parent's listing and its own `open` (`isGone`) is appended dead: it is not unreadable, just no longer there.
    /// `checkRootDevice` (updates): each of `ids` is opened by path and may have become another volume's mount point
    /// since the snapshot; it is then gone with `EXDEV`. A full scan leaves it off: there the root defines the device.
    static func rescanSubtrees(
        _ ids: [Int32], in tree: DiskTree, options: ScanOptions, checkRootDevice: Bool = false,
        progress: ScanProgress? = nil
    ) -> [Int32: Int32] {
        guard !ids.isEmpty else { return [:] }
        let job = ParallelScan(
            roots: ids.map { ($0, tree.path(of: Int($0)), tree.cPath(of: Int($0))) },
            rootDev: tree.rootDev, options: options, exclusions: tree.exclusions, hardlinks: tree.hardlinks,
            clones: tree.clones, idBase: Int32(tree.nodes.count), checkRootDevice: checkRootDevice,
            allocUnit: allocationUnit(of: tree.rootPath), progress: progress)
        job.run()
        let rootCount = Int32(ids.count)
        for (i, id) in ids.enumerated() {
            tree.nodes[Int(id)].ownAlloc = job.nodes[i].ownAlloc
            tree.nodes[Int(id)].ownLogical = job.nodes[i].ownLogical
            tree.nodes[Int(id)].ownFiles = job.nodes[i].ownFiles
            tree.nodes[Int(id)].ownCloneAware = job.nodes[i].ownCloneAware
            tree.nodes[Int(id)].unreadable = job.nodes[i].unreadable
            tree.nodes[Int(id)].incomplete = job.nodes[i].incomplete
        }
        let base = Int32(tree.nodes.count)
        // One bulk append: grows geometrically, unlike an exact reserveCapacity on every update.
        tree.nodes.append(
            contentsOf: job.nodes.dropFirst(ids.count).lazy.map { n in
                var n = n
                if n.isDead { return n }
                n.parent = n.parent < rootCount ? ids[Int(n.parent)] : base + n.parent - rootCount
                return n
            })
        for (local, bytes) in job.rawNames { tree.rawNames[base + local - rootCount] = bytes }
        tree.stats.merge(job.stats)
        tree.mountPoints += job.mountPoints
        return Dictionary(job.failedRoots.map { (ids[Int($0.id)], $0.errno) }, uniquingKeysWith: { a, _ in a })
    }

    /// The allocation unit to round to for a listing that omits `ALLOCSIZE`: `f_bsize`, the cluster size, of a FAT
    /// (`msdos`) volume. 0 for every other file system, whose data lengths are then counted as they are (exFAT reports
    /// `ALLOCSIZE`; a macFUSE or FSKit volume may hold sparse or compressed files that no rounding gets right).
    static func allocationUnit(_ fs: statfs) -> Int64 {
        var fs = fs
        let isFAT = withUnsafePointer(to: &fs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { strcmp($0, "msdos") == 0 }
        }
        return isFAT ? Int64(fs.f_bsize) : 0
    }

    /// One `statfs` per scan or update (and per mounted volume entered with `--cross-devices`), never per file.
    static func allocationUnit(of path: String) -> Int64 {
        var fs = statfs()
        return statfs(path, &fs) == 0 ? allocationUnit(fs) : 0
    }

    static func preventCloudDownloads() {
        // Touching iCloud/Dropbox placeholders must not trigger a File Provider download.
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    static func nowNanoseconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    static func volumeUUID(_ dev: dev_t) -> String {
        guard let uuid = FSEventsCopyUUIDForDevice(dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

// MARK: - Parallel engine

private struct WorkItem {
    let id: Int32
    /// Display path; exact unless `cPath` is set.
    let path: String
    /// NUL-terminated bytes to open when a component of the path is not valid UTF-8 (`DiskTree.rawNames`).
    var cPath: [CChar]? = nil
    /// Its own name is not valid UTF-8. Such a folder can exist and still not open by its bytes (a FAT volume with a
    /// lone UTF-16 surrogate), so `ENOENT` does not prove it gone.
    var rawName = false
    /// The directory's own allocation from its parent's listing (0 on APFS); added to its node when it is read.
    var selfAlloc: Int64 = 0
    /// The allocation unit of the volume this directory is on (inherited from the parent; a mounted volume has its own).
    var allocUnit: Int64 = 0
    /// A mounted volume's root entered with `--cross-devices`: the listing gave the covered folder's attributes, so the
    /// read takes its own `fstat` and `fstatfs`.
    var volumeRoot = false

    /// The parent directory still exists at its path (one `lstat`; only for a child that turned out gone).
    var parentExists: Bool {
        var st = stat()
        if let cPath {
            let bytes = cPath.dropLast()
            guard let slash = bytes.lastIndex(of: CChar(UInt8(ascii: "/"))) else { return true }
            var parent = Array(bytes[..<slash])
            if parent.isEmpty { parent = [CChar(UInt8(ascii: "/"))] }
            parent.append(0)
            return lstat(parent, &st) == 0
        }
        return lstat((path as NSString).deletingLastPathComponent, &st) == 0
    }
}

private final class ParallelScan: @unchecked Sendable {
    let options: ScanOptions
    let config: DirReader.Config
    let hardlinks: HardlinkRegistry
    let clones: CloneRegistry
    let rootIds: [Int32]
    let idBase: Int32
    /// Root items check their own device (`DirReader.read(checkOwnDevice:)`); the others were checked by a listing.
    let checkRootDevice: Bool
    let progress: ScanProgress?

    // `cond` guards: nodes, queue, active, stats, finished, failedRoots, mountPoints, rawNames
    let cond = NSCondition()
    var nodes: [DirNode]
    var queue: [WorkItem]
    var active = 0
    var finished = 0
    var stats = ScanStats()
    var failedRoots: [(id: Int32, errno: Int32)] = []
    /// Skipped mount points, with the global id of the directory that lists them.
    var mountPoints: [MountPoint] = []
    /// Raw bytes of child names that are not valid UTF-8, by local id (never a root's).
    var rawNames: [Int32: [UInt8]] = [:]

    /// Local ids 0..<roots.count are the roots; everything found below them is appended after.
    init(
        roots: [(id: Int32, path: String, cPath: [CChar]?)], rootDev: dev_t, options: ScanOptions,
        exclusions: [String: Set<String>], hardlinks: HardlinkRegistry, clones: CloneRegistry, idBase: Int32,
        checkRootDevice: Bool, allocUnit: Int64,
        progress: ScanProgress?
    ) {
        self.options = options
        self.checkRootDevice = checkRootDevice
        self.progress = progress
        self.config = DirReader.Config(
            rootDev: rootDev, options: options, exclusions: exclusions, allocUnit: allocUnit)
        self.hardlinks = hardlinks
        self.clones = clones
        self.rootIds = roots.map(\.id)
        self.idBase = idBase
        nodes = roots.map { DirNode(parent: -1, name: $0.path) }
        nodes.reserveCapacity(1 << 12)
        queue = roots.indices.reversed().map {
            WorkItem(id: Int32($0), path: roots[$0].path, cPath: roots[$0].cPath, allocUnit: allocUnit)
        }
    }

    /// Ids handed to the hardlink registry are the ids nodes will have once grafted into the tree.
    func globalId(_ local: Int32) -> Int32 {
        local < rootIds.count ? rootIds[Int(local)] : idBase + local - Int32(rootIds.count)
    }

    func run() {
        let threads = (0..<options.threads).map { _ in
            let t = Thread { self.workerLoop() }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            return t
        }
        threads.forEach { $0.start() }
        cond.lock()
        while finished < options.threads { cond.wait() }
        cond.unlock()
    }

    private func workerLoop() {
        let reader = DirReader(config)
        defer { reader.deallocate() }
        // Reused for every directory this worker reads. Set before the workers start, the cutoff is fixed meanwhile.
        var links = LinkBatch(keepNames: hardlinks.birthCutoff != nil)

        cond.lock()
        while true {
            while queue.isEmpty {
                if active == 0 {
                    finished += 1
                    cond.broadcast()
                    cond.unlock()
                    return
                }
                cond.wait()
            }
            // LIFO: depth-first traversal keeps the queue small.
            let item = queue.removeLast()
            active += 1
            cond.unlock()

            let gid = globalId(item.id)
            let isRoot = item.id < rootIds.count
            let ownStat = isRoot || item.volumeRoot
            var out = reader.read(
                item.path, cPath: item.cPath, checkOwnDevice: checkRootDevice && isRoot, statSelf: ownStat,
                allocUnit: item.allocUnit, links: &links)
            if !links.links.isEmpty {
                // One lock per directory, not per file (chapter 01 §4.4).
                let c = hardlinks.claim(&links, by: gid, dirPath: item.path)
                out.alloc += c.alloc
                out.logical += c.logical
                out.cloneAware += c.cloneAware
                out.files += c.files
                out.stats.hardlinkDupes += c.dupes
            }
            if !out.cloneMembers.isEmpty {
                // One lock per directory, not per file.
                let c = clones.claim(out.cloneMembers, by: gid)
                out.cloneAware += c.bytes
                out.stats.cloneDupes += c.dupes
            }
            progress?.add(files: out.files, bytes: out.cloneAware)
            // Gone between its parent's listing and its own open. If the parent's path is gone too (renamed or removed
            // during the walk), whatever the parent held is lost from here on: the parent is flagged incomplete.
            let vanished = out.isGone && item.id >= rootIds.count && !item.rawName
            let parentLost = vanished && !item.parentExists

            cond.lock()
            if item.id < rootIds.count && out.isGone { failedRoots.append((item.id, out.openError)) }
            // The folder's own clusters count in the folder itself, as `du` counts them (0 on APFS and HFS+).
            let own = out.opened ? (ownStat ? out.selfAlloc : item.selfAlloc) : 0
            nodes[Int(item.id)].ownAlloc = out.alloc + own
            nodes[Int(item.id)].ownLogical = out.logical
            nodes[Int(item.id)].ownFiles = out.files
            nodes[Int(item.id)].ownCloneAware = out.cloneAware + own
            if vanished {
                // Removed (or replaced by a file or symlink) after its parent listed it. `openErrors` still counts it.
                if parentLost { nodes[Int(nodes[Int(item.id)].parent)].incomplete = true }
                nodes[Int(item.id)].parent = DirNode.dead
            } else {
                nodes[Int(item.id)].unreadable = !out.opened
            }
            nodes[Int(item.id)].incomplete = out.incomplete
            stats.merge(out.stats)
            for name in out.mountPoints { mountPoints.append(MountPoint(parent: gid, name: name)) }
            let base = item.path == "/" ? "" : item.path
            if item.cPath == nil && out.rawChildDirs.isEmpty {
                var next = 0  // out.childAllocs holds only the non-zero ones, in index order
                var nextMount = 0
                for (k, name) in out.childDirs.enumerated() {
                    let id = Int32(nodes.count)
                    nodes.append(DirNode(parent: item.id, name: name, fileID: out.childIDs[k]))
                    var selfAlloc: Int64 = 0
                    if next < out.childAllocs.count && out.childAllocs[next].index == k {
                        selfAlloc = out.childAllocs[next].alloc
                        next += 1
                    }
                    var volumeRoot = false
                    if nextMount < out.crossedMounts.count && out.crossedMounts[nextMount] == k {
                        volumeRoot = true
                        nextMount += 1
                    }
                    queue.append(
                        WorkItem(
                            id: id, path: base + "/" + name, selfAlloc: selfAlloc, allocUnit: out.allocUnit,
                            volumeRoot: volumeRoot))
                }
            } else {
                // Rare: a name that is not valid UTF-8 here or above; the children are opened by their bytes.
                let raw = Dictionary(out.rawChildDirs.map { ($0.index, $0.bytes) }, uniquingKeysWith: { a, _ in a })
                let parentBytes = item.cPath.map { $0.dropLast().map { UInt8(bitPattern: $0) } } ?? Array(base.utf8)
                var next = 0
                var nextMount = 0
                for (k, name) in out.childDirs.enumerated() {
                    var selfAlloc: Int64 = 0
                    if next < out.childAllocs.count && out.childAllocs[next].index == k {
                        selfAlloc = out.childAllocs[next].alloc
                        next += 1
                    }
                    var volumeRoot = false
                    if nextMount < out.crossedMounts.count && out.crossedMounts[nextMount] == k {
                        volumeRoot = true
                        nextMount += 1
                    }
                    let id = Int32(nodes.count)
                    nodes.append(DirNode(parent: item.id, name: name, fileID: out.childIDs[k]))
                    if let r = raw[k] { rawNames[id] = r }
                    let bytes = parentBytes + [UInt8(ascii: "/")] + (raw[k] ?? Array(name.utf8)) + [0]
                    queue.append(
                        WorkItem(
                            id: id, path: base + "/" + name, cPath: bytes.map { CChar(bitPattern: $0) },
                            rawName: raw[k] != nil, selfAlloc: selfAlloc, allocUnit: out.allocUnit,
                            volumeRoot: volumeRoot))
                }
            }
            active -= 1
            if out.childDirs.count > 1 || (queue.isEmpty && active == 0) {
                cond.broadcast()
            } else if out.childDirs.count == 1 {
                cond.signal()
            }
        }
    }
}

// MARK: - Single directory reader

struct DirOutcome {
    var alloc: Int64 = 0
    var logical: Int64 = 0
    var files: Int64 = 0
    /// Clone-aware bytes of the files counted here, without the full clones in `cloneMembers` (claimed by the caller).
    var cloneAware: Int64 = 0
    /// Full-clone files counted here (not hard-linked); the caller claims them in the `CloneRegistry`.
    var cloneMembers: [CloneMember] = []
    var childDirs: [String] = []
    /// `ATTR_CMN_FILEID` of each entry of `childDirs` (0 when the listing did not return it), in the same order.
    var childIDs: [UInt64] = []
    /// Own allocation of the child directories whose listing gave a non-zero one (FAT, exFAT; never on APFS or HFS+),
    /// by index into `childDirs`, in index order.
    var childAllocs: [(index: Int, alloc: Int64)] = []
    /// Allocation of this directory itself (`st_blocks` x 512), only when the read took an `fstat` (`statSelf`, or the
    /// device check).
    var selfAlloc: Int64 = 0
    /// The allocation unit this directory's records were rounded to, and its children inherit.
    var allocUnit: Int64 = 0
    /// Indices into `childDirs` of mount points entered with `--cross-devices`, in index order.
    var crossedMounts: [Int] = []
    /// Raw bytes of the entries of `childDirs` whose names are not valid UTF-8 (`childDirs` holds a display form).
    var rawChildDirs: [(index: Int, bytes: [UInt8])] = []
    /// Indices into `childDirs` of the child directories the caller may not list (no read or search permission); only
    /// with `Config.userAccess`.
    var deniedChildDirs: [Int] = []
    /// Child directories skipped because another volume is mounted on them (not with `crossDevices`).
    var mountPoints: [String] = []
    /// Multiply-linked files of an update re-read (`Incremental.readDirectories`), claimed after the old records are
    /// dropped. Empty in a scan, which claims its `LinkBatch` right after the read.
    var deferredLinks: [(inode: UInt64, alloc: Int64, logical: Int64, cloneAware: Int64)] = []
    var stats = ScanStats()
    var opened = true
    /// Opened, but not every entry could be read (`getattrlistbulk` failed, or an entry carried `ATTR_CMN_ERROR`).
    var incomplete = false
    /// errno of the failed `open`, 0 if it opened.
    var openError: Int32 = 0

    /// The directory no longer exists as a directory, or (`EXDEV`, `Config.checkOwnDevice`) it is now another volume's
    /// mount point, which a full scan never enters. Any other failure (EACCES, EPERM, ...) leaves it in the tree,
    /// empty, as a full scan does.
    var isGone: Bool {
        !opened && (openError == ENOENT || openError == ENOTDIR || openError == ELOOP || openError == EXDEV)
    }
}

/// Reads all entries of one directory in bulk via getattrlistbulk.
/// No syscall per entry: one call fills a 256 KB buffer with hundreds of entries.
struct DirReader {
    struct Config: Sendable {
        let rootDev: dev_t
        let options: ScanOptions
        /// Also report child directories we lack permission to list (ATTR_CMN_USERACCESS); incremental re-reads use
        /// it because FSEvents reports a permission change on the parent, not on the directory itself.
        var userAccess = false
        /// Directory path -> child directories not to descend into (data-volume twins of firmlinks).
        var exclusions: [String: Set<String>] = [:]
        /// `fstat` the directory after `open` and refuse it (`EXDEV`) when it is on another device. For directories an
        /// update opens on their own: a listing checks its children, but nothing has checked these since the snapshot,
        /// and one may now be a mount point. One syscall per directory, none per file.
        var checkOwnDevice = false
        /// Allocation unit of the volume (`Scanner.allocationUnit(of:)`): a record without `ALLOCSIZE` counts its data
        /// length rounded up to it. Decided by the volume, read once per scan or update, never per file.
        var allocUnit: Int64 = 0
        #if DEBUG
            let faults: DirFaults
        #endif

        init(
            rootDev: dev_t, options: ScanOptions, userAccess: Bool = false, exclusions: [String: Set<String>] = [:],
            checkOwnDevice: Bool = false, allocUnit: Int64 = 0
        ) {
            self.allocUnit = allocUnit
            self.rootDev = rootDev
            self.options = options
            self.userAccess = userAccess
            self.exclusions = exclusions
            self.checkOwnDevice = checkOwnDevice
            #if DEBUG
                faults = options.faults
            #endif
        }
    }

    static let bufSize = 256 * 1024
    let config: Config
    let buf: UnsafeMutableRawPointer

    init(_ config: Config) {
        self.config = config
        buf = UnsafeMutableRawPointer.allocate(byteCount: DirReader.bufSize, alignment: 16)
    }

    func deallocate() { buf.deallocate() }

    /// Multiply-linked regular files are not counted in the outcome: `links` (emptied first) receives them, and the
    /// caller claims or defers them as one batch (chapter 01 §4.4). `checkOwnDevice` overrides `Config.checkOwnDevice`
    /// for this directory. `cPath`, when set, is what is opened (NUL-terminated bytes; `path` is then only a display
    /// form).
    func read(
        _ path: String, cPath: [CChar]? = nil, checkOwnDevice: Bool? = nil, statSelf: Bool = false,
        allocUnit: Int64? = nil, links: inout LinkBatch
    ) -> DirOutcome {
        links.reset()
        var out = DirOutcome()
        #if DEBUG
            if config.faults.removeBeforeOpen.contains(path) { try? FileManager.default.removeItem(atPath: path) }
            if let move = config.faults.renameBeforeOpen[path], move.count == 2 { rename(move[0], move[1]) }
        #endif
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let fd = cPath.map { open($0, flags) } ?? open(path, flags)
        guard fd >= 0 else {
            out.openError = errno
            out.opened = false
            out.stats.openErrors = 1
            return out
        }
        defer { close(fd) }
        var unit = allocUnit ?? config.allocUnit
        let checkDevice = (checkOwnDevice ?? config.checkOwnDevice) && !config.options.crossDevices
        if checkDevice || statSelf {
            // One `fstat` for the directories that need it, none per file.
            var st = stat()
            if fstat(fd, &st) == 0 {
                if checkDevice && st.st_dev != config.rootDev {
                    out.openError = EXDEV
                    out.opened = false
                    out.stats.mountsSkipped = 1
                    return out
                }
                out.selfAlloc = Int64(st.st_blocks) * 512
                if st.st_dev != config.rootDev {
                    // Another volume (only with `--cross-devices`): its own unit, one `fstatfs` per volume entered.
                    var fs = statfs()
                    unit = fstatfs(fd, &fs) == 0 ? Scanner.allocationUnit(fs) : 0
                }
            }
        }
        out.allocUnit = unit

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        al.fileattr =
            attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
        if config.userAccess { al.commonattr |= attrgroup_t(ATTR_CMN_USERACCESS) }
        // Directories only: a mount point is listed with the attributes of the directory underneath it.
        // Own allocation and length of a child directory: FAT has only the length, exFAT both, APFS a zero allocation.
        al.dirattr =
            attrgroup_t(ATTR_DIR_MOUNTSTATUS) | attrgroup_t(ATTR_DIR_ALLOCSIZE) | attrgroup_t(ATTR_DIR_DATALENGTH)
        // Clone id and extended flags are inode fields: cheap, unlike PRIVATESIZE, which walks the extents.
        al.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        if config.options.privateSize { al.forkattr |= attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) }
        let opts = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_ATTR_CMN_EXTENDED)
        let skip = config.exclusions.isEmpty ? nil : config.exclusions[path]

        #if DEBUG
            var faultCall = 0
            let bulkFaults = config.faults.bulk[path] ?? []
            var entryFault = config.faults.entryError.contains(path)
        #endif
        var interrupted = 0
        while true {
            let count: Int32
            #if DEBUG
                if faultCall < bulkFaults.count && bulkFaults[faultCall] != 0 {
                    count = -1
                    errno = bulkFaults[faultCall]
                } else {
                    count = getattrlistbulk(fd, &al, buf, DirReader.bufSize, opts)
                }
                faultCall += 1
            #else
                count = getattrlistbulk(fd, &al, buf, DirReader.bufSize, opts)
            #endif
            if count == 0 { break }
            if count < 0 {
                // Entries already parsed stay; an interrupted call is made again, up to 3 times in a row.
                if errno == EINTR && interrupted < 3 {
                    interrupted += 1
                    continue
                }
                out.stats.entryErrors += 1
                out.incomplete = true
                break
            }
            interrupted = 0
            #if DEBUG
                if entryFault {
                    entryFault = false
                    Self.injectEntryError(buf)
                }
            #endif
            var entry = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                parseEntry(
                    entry + 4, into: &out, dirPath: path, dirCPath: cPath, skip: skip, unit: unit, batch: &links)
                entry += length
            }
        }
        return out
    }

    /// `st_dev` of the volume mounted on `dirPath/name`, from `lstat` (as `du -x` sees it). Built from bytes, so a name
    /// that is not valid UTF-8 is found too.
    /// Also returns the volume root's own allocation (`st_blocks` x 512), which `du -x` counts for a mount point it skips.
    private static func mountedVolume(
        _ dirPath: String, _ dirCPath: [CChar]?, _ name: UnsafeRawPointer
    ) -> (dev: dev_t, alloc: Int64)? {
        var path =
            dirCPath.map { Array($0.dropLast()) }
            ?? (dirPath == "/" ? [] : dirPath.utf8.map { CChar(bitPattern: $0) })
        path.append(CChar(UInt8(ascii: "/")))
        let cName = name.assumingMemoryBound(to: CChar.self)
        path += UnsafeBufferPointer(start: cName, count: strlen(cName))
        path.append(0)
        var st = stat()
        return lstat(path, &st) == 0 ? (st.st_dev, Int64(st.st_blocks) * 512) : nil
    }

    /// `length` rounded up to the volume's allocation unit (0 stays 0; unchanged when the unit is unknown).
    @inline(__always)
    private func roundedUp(_ length: Int64, _ unit: Int64) -> Int64 {
        return unit > 0 ? (length + unit - 1) / unit * unit : length
    }

    // Fields are packed in sys/attr.h bit order (common, directory, file, fork); ERROR comes right after RETURNED_ATTRS.
    @inline(__always)
    private func parseEntry(
        _ start: UnsafeRawPointer, into out: inout DirOutcome, dirPath: String, dirCPath: [CChar]?,
        skip: Set<String>?, unit: Int64, batch: inout LinkBatch
    ) {
        var f = start
        let returned = f.loadUnaligned(as: attribute_set_t.self)
        f += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let err = f.loadUnaligned(as: UInt32.self)
            f += 4
            if err != 0 {
                out.stats.entryErrors += 1
                out.incomplete = true
                return
            }
        }
        var namePtr: UnsafeRawPointer?
        if common & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let ref = f.loadUnaligned(as: attrreference_t.self)
            namePtr = f + Int(ref.attr_dataoffset)
            f += MemoryLayout<attrreference_t>.size
        }
        var dev = config.rootDev
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            dev = f.loadUnaligned(as: dev_t.self)
            f += 4
        }
        var type: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            type = f.loadUnaligned(as: UInt32.self)
            f += 4
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = f.loadUnaligned(as: UInt32.self)
            f += 4
        }
        #if DEBUG
            // chflags(2) cannot set SF_DATALESS (the kernel ignores it), so tests name the entries to report as placeholders.
            if !config.faults.dataless.isEmpty, let namePtr,
                config.faults.dataless.contains(String(cString: namePtr.assumingMemoryBound(to: CChar.self)))
            {
                flags |= UInt32(SF_DATALESS)
            }
        #endif
        var access = UInt32(R_OK | X_OK)
        if common & attrgroup_t(ATTR_CMN_USERACCESS) != 0 {
            access = f.loadUnaligned(as: UInt32.self)
            f += 4
        }
        var fileID: UInt64 = 0
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            fileID = f.loadUnaligned(as: UInt64.self)
            f += 8
        }
        var mountStatus: UInt32 = 0
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            mountStatus = f.loadUnaligned(as: UInt32.self)
            f += 4
        }
        var dirAlloc: Int64 = 0
        if returned.dirattr & attrgroup_t(ATTR_DIR_ALLOCSIZE) != 0 {
            dirAlloc = f.loadUnaligned(as: Int64.self)
            f += 8
        }
        var dirLength: Int64 = 0
        if returned.dirattr & attrgroup_t(ATTR_DIR_DATALENGTH) != 0 {
            dirLength = f.loadUnaligned(as: Int64.self)
            f += 8
            // No ALLOCSIZE (FAT): the folder's clusters, as `du` counts them.
            if returned.dirattr & attrgroup_t(ATTR_DIR_ALLOCSIZE) == 0 { dirAlloc = roundedUp(dirLength, unit) }
        }

        if type == UInt32(VDIR.rawValue) {
            var mountAlloc: Int64 = 0
            if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 && !config.options.crossDevices, let namePtr {
                // DEVID is the covered directory's; the mounted volume's root decides, as for du -x. One syscall per
                // mount point, none per file. If lstat fails the device is unknown: not entered.
                if let volume = Self.mountedVolume(dirPath, dirCPath, namePtr) {
                    dev = volume.dev
                    mountAlloc = volume.alloc
                } else {
                    dev = ~config.rootDev
                }
            }
            if dev != config.rootDev && !config.options.crossDevices {
                out.stats.mountsSkipped += 1
                // A skipped mount point still costs its own cluster in the folder that lists it (FAT; 0 on APFS, HFS+).
                out.alloc += mountAlloc
                out.cloneAware += mountAlloc
                // Recorded so that an update finds the folder again after an unmount (no event marks it).
                if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0, let namePtr {
                    out.mountPoints.append(String(cString: namePtr.assumingMemoryBound(to: CChar.self)))
                }
                return
            }
            if flags & UInt32(SF_DATALESS) != 0 { out.stats.datalessDirs += 1; return }
            if let namePtr {
                let cName = namePtr.assumingMemoryBound(to: CChar.self)
                // Same validation work as String(cString:), without its silent repair.
                let valid = String(validatingCString: cName)
                let name = valid ?? String(cString: cName)
                if let skip, skip.contains(name) { out.stats.firmlinksSkipped += 1; return }
                if access & UInt32(R_OK | X_OK) != UInt32(R_OK | X_OK) {
                    out.deniedChildDirs.append(out.childDirs.count)
                }
                if valid == nil {
                    // Not UTF-8: `name` (with U+FFFD) is for display; the walk opens the raw bytes.
                    out.rawChildDirs.append(
                        (
                            out.childDirs.count,
                            Array(UnsafeRawBufferPointer(start: namePtr, count: strlen(cName)))
                        ))
                }
                if dirAlloc != 0 { out.childAllocs.append((out.childDirs.count, dirAlloc)) }
                // Entered mount point: the attributes above are the covered folder's; the read asks the volume itself.
                if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 { out.crossedMounts.append(out.childDirs.count) }
                out.childDirs.append(name)
                out.childIDs.append(fileID)
            }
            return
        }

        let fileAttrs = returned.fileattr
        var links: UInt32 = 1
        if fileAttrs & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            links = f.loadUnaligned(as: UInt32.self)
            f += 4
        }
        var alloc: Int64 = 0
        let hasAlloc = fileAttrs & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0
        if hasAlloc {
            alloc = f.loadUnaligned(as: Int64.self)
            f += 8
        }
        var logical: Int64 = 0
        if fileAttrs & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            logical = f.loadUnaligned(as: Int64.self)
            f += 8
            // The volume does not report allocations (FAT): whole clusters, as `du` counts them.
            if !hasAlloc { alloc = roundedUp(logical, unit) }
        }
        // Fork (CMNEXT) fields follow in bit order: PRIVATESIZE, CLONEID, EXT_FLAGS.
        let fork = returned.forkattr
        let realAlloc = alloc
        if fork & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
            alloc = f.loadUnaligned(as: Int64.self)
            f += 8
        }
        var cloneID: UInt64 = 0
        if fork & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
            cloneID = f.loadUnaligned(as: UInt64.self)
            f += 8
        }
        var extFlags: UInt64 = 0
        if fork & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
            extFlags = f.loadUnaligned(as: UInt64.self)
            f += 8
        }

        if flags & UInt32(SF_DATALESS) != 0 {
            out.stats.datalessLogical += logical
            out.files += 1
            return
        }
        if links > 1 && type == UInt32(VREG.rawValue) {
            // A hard-linked file counts once with its full size; it is not deduplicated as a clone. The caller claims
            // the whole batch after the read and adds what is counted here.
            batch.append(
                fileID, alloc: alloc, logical: logical, cloneAware: realAlloc,
                name: namePtr?.assumingMemoryBound(to: CChar.self))
            return
        } else if extFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 && cloneID != 0 && type == UInt32(VREG.rawValue) {
            out.cloneMembers.append(CloneMember(cloneID: cloneID, alloc: realAlloc, isOriginal: cloneID == fileID))
        } else {
            // Not a full clone: the whole allocation (a partial clone's shared blocks cannot be attributed; see spec).
            out.cloneAware += realAlloc
        }
        out.alloc += alloc
        out.logical += logical
        out.files += 1
    }
}

#if DEBUG
    /// Test-only faults for `DirReader.read`, keyed by the directory's path as the reader gets it. Compiled out of release
    /// builds, so the release hot path has no trace of them.
    struct DirFaults: Sendable {
        /// errno for successive `getattrlistbulk` calls of a directory instead of calling it; 0 makes the real call.
        var bulk: [String: [Int32]] = [:]
        /// Directories whose first listed entry is reported with `ATTR_CMN_ERROR` = `EIO`.
        var entryError: Set<String> = []
        /// Directories removed, with their contents, right before they are opened (gone between listing and opening).
        var removeBeforeOpen: Set<String> = []
        /// Right before the key path is opened, the first path of the value is renamed to the second.
        var renameBeforeOpen: [String: [String]] = [:]
        /// Names of entries (in any directory) reported with `SF_DATALESS` set, as a cloud placeholder is.
        var dataless: Set<String> = []
        /// Faults for `EventHistory.fetch`; see `HistoryFaults`.
        var history = HistoryFaults()

        /// From `FIL_TEST_FAULTS` (debug builds only, for tests of the `fil` binary): one fault per line,
        /// `bulk <errno>[,<errno>...] <path>`, `entry <path>` or `remove <path>`.
        static let environment: DirFaults = {
            var f = DirFaults()
            guard let spec = ProcessInfo.processInfo.environment["FIL_TEST_FAULTS"] else { return f }
            for line in spec.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "bulk":
                    let rest = parts[1].split(separator: " ", maxSplits: 1)
                    guard rest.count == 2 else { continue }
                    f.bulk[String(rest[1])] = rest[0].split(separator: ",").compactMap { Int32($0) }
                case "entry": f.entryError.insert(String(parts[1]))
                case "remove": f.removeBeforeOpen.insert(String(parts[1]))
                default: continue
                }
            }
            return f
        }()
    }

    /// Test-only faults for the FSEvents replay of an incremental update. Compiled out of release builds.
    struct HistoryFaults: Sendable {
        /// Seconds to wait for HistoryDone and for the barrier event instead of the real limits (30 and 2).
        var historyLimit: Int?
        var barrierLimit: Int?
        /// HistoryDone is never seen, so the replay times out.
        var dropHistoryDone = false
        /// The barrier event is never recognised, so the wait for it times out.
        var dropBarrier = false
        /// OR-ed into the flags of every event of the replay (a `kFSEventStreamEventFlag...` lost-history flag).
        var extraFlags: FSEventStreamEventFlags = 0
    }

    extension DirReader {
        /// Turns the first record in `buf` into an error record (`ATTR_CMN_ERROR` = `EIO`, nothing else returned), as the
        /// kernel reports an entry it cannot return. The record keeps its length; the rest of it is never read.
        static func injectEntryError(_ buf: UnsafeMutableRawPointer) {
            var returned = attribute_set_t()
            returned.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            (buf + 4).storeBytes(of: returned, as: attribute_set_t.self)
            (buf + 4 + MemoryLayout<attribute_set_t>.size).storeBytes(of: UInt32(EIO), as: UInt32.self)
        }
    }
#endif
