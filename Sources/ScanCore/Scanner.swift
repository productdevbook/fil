import CoreServices
import Darwin
import Foundation
import Synchronization

/// Live counters of a running scan, safe to read from any thread while workers update them.
/// Workers add once per directory read, never per file.
public final class ScanProgress: Sendable {
    public let dirs = Atomic<Int64>(0)
    public let files = Atomic<Int64>(0)
    /// On-disk (allocated) bytes counted so far.
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
    public static func scan(_ path: String, options: ScanOptions = ScanOptions(),
                            progress: ScanProgress? = nil) throws -> DiskTree {
        preventCloudDownloads()
        var st = stat()
        guard lstat(path, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let scanStart = nowNanoseconds()
        // Taken before walking: anything that changes during the scan is replayed next time.
        let eventId = FSEventsGetCurrentEventId()
        let tree = DiskTree(rootPath: path, rootDev: st.st_dev, privateSize: options.privateSize,
                            nodes: [DirNode(parent: -1, name: path)], eventId: eventId,
                            volumeUUID: volumeUUID(st.st_dev), scanStart: scanStart, hardlinks: HardlinkRegistry())
        _ = rescanSubtrees([0], in: tree, options: options, progress: progress)
        tree.computeTotals()
        return tree
    }

    /// Scans the subtrees under existing nodes `ids` in one parallel pass. Their old descendants must
    /// already be dead; new descendants are appended to the tree. Returns the ids whose directory is gone
    /// (`DirOutcome.isGone`) with the errno of the failed `open`; an unreadable root stays, empty, like in a full scan.
    static func rescanSubtrees(_ ids: [Int32], in tree: DiskTree, options: ScanOptions,
                               progress: ScanProgress? = nil) -> [Int32: Int32] {
        guard !ids.isEmpty else { return [:] }
        let job = ParallelScan(roots: ids.map { ($0, tree.path(of: Int($0))) }, rootDev: tree.rootDev,
                               options: options, hardlinks: tree.hardlinks, idBase: Int32(tree.nodes.count),
                               progress: progress)
        job.run()
        let rootCount = Int32(ids.count)
        for (i, id) in ids.enumerated() {
            tree.nodes[Int(id)].ownAlloc = job.nodes[i].ownAlloc
            tree.nodes[Int(id)].ownLogical = job.nodes[i].ownLogical
            tree.nodes[Int(id)].ownFiles = job.nodes[i].ownFiles
            tree.nodes[Int(id)].unreadable = job.nodes[i].unreadable
        }
        let base = Int32(tree.nodes.count)
        // One bulk append: grows geometrically, unlike an exact reserveCapacity on every update.
        tree.nodes.append(contentsOf: job.nodes.dropFirst(ids.count).lazy.map { n in
            var n = n
            n.parent = n.parent < rootCount ? ids[Int(n.parent)] : base + n.parent - rootCount
            return n
        })
        tree.stats.merge(job.stats)
        return Dictionary(job.failedRoots.map { (ids[Int($0.id)], $0.errno) }, uniquingKeysWith: { a, _ in a })
    }

    static func preventCloudDownloads() {
        // Touching iCloud/Dropbox placeholders must not trigger a File Provider download.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
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
    let path: String
}

private final class ParallelScan: @unchecked Sendable {
    let options: ScanOptions
    let config: DirReader.Config
    let hardlinks: HardlinkRegistry
    let rootIds: [Int32]
    let idBase: Int32
    let progress: ScanProgress?

    // `cond` guards: nodes, queue, active, stats, finished, failedRoots
    let cond = NSCondition()
    var nodes: [DirNode]
    var queue: [WorkItem]
    var active = 0
    var finished = 0
    var stats = ScanStats()
    var failedRoots: [(id: Int32, errno: Int32)] = []

    /// Local ids 0..<roots.count are the roots; everything found below them is appended after.
    init(roots: [(id: Int32, path: String)], rootDev: dev_t, options: ScanOptions,
         hardlinks: HardlinkRegistry, idBase: Int32, progress: ScanProgress?) {
        self.options = options
        self.progress = progress
        self.config = DirReader.Config(rootDev: rootDev, options: options)
        self.hardlinks = hardlinks
        self.rootIds = roots.map(\.id)
        self.idBase = idBase
        nodes = roots.map { DirNode(parent: -1, name: $0.path) }
        nodes.reserveCapacity(1 << 12)
        queue = roots.indices.reversed().map { WorkItem(id: Int32($0), path: roots[$0].path) }
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
            let out = reader.read(item.path) { inode, alloc, logical, name in
                self.hardlinks.vet(inode, alloc: alloc, dirPath: item.path, name: name)
                return self.hardlinks.claim(inode, by: gid, alloc: alloc, logical: logical)
            }
            progress?.add(files: out.files, bytes: out.alloc)

            cond.lock()
            if item.id < rootIds.count && out.isGone { failedRoots.append((item.id, out.openError)) }
            nodes[Int(item.id)].ownAlloc = out.alloc
            nodes[Int(item.id)].ownLogical = out.logical
            nodes[Int(item.id)].ownFiles = out.files
            nodes[Int(item.id)].unreadable = !out.opened
            stats.merge(out.stats)
            let base = item.path == "/" ? "" : item.path
            for name in out.childDirs {
                let id = Int32(nodes.count)
                nodes.append(DirNode(parent: item.id, name: name))
                queue.append(WorkItem(id: id, path: base + "/" + name))
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
    var childDirs: [String] = []
    /// Child directories the caller may not list (no read or search permission); only with `Config.userAccess`.
    var deniedChildDirs: [String] = []
    /// Multiply-linked files whose claim was deferred (the claim closure returned nil).
    var deferredLinks: [(inode: UInt64, alloc: Int64, logical: Int64)] = []
    var stats = ScanStats()
    var opened = true
    /// errno of the failed `open`, 0 if it opened.
    var openError: Int32 = 0

    /// The directory no longer exists as a directory. Any other failure (EACCES, EPERM, ...) leaves it in the
    /// tree, empty, as a full scan does.
    var isGone: Bool { !opened && (openError == ENOENT || openError == ENOTDIR || openError == ELOOP) }
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
    }

    static let bufSize = 256 * 1024
    let config: Config
    let buf: UnsafeMutableRawPointer

    init(_ config: Config) {
        self.config = config
        buf = UnsafeMutableRawPointer.allocate(byteCount: DirReader.bufSize, alignment: 16)
    }

    func deallocate() { buf.deallocate() }

    /// `claim` decides whether a multiply-linked inode is counted here; returning nil defers it.
    func read(_ path: String, claim: (UInt64, Int64, Int64, UnsafePointer<CChar>?) -> Bool?) -> DirOutcome {
        var out = DirOutcome()
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            out.openError = errno
            out.opened = false
            out.stats.openErrors = 1
            return out
        }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
        if config.userAccess { al.commonattr |= attrgroup_t(ATTR_CMN_USERACCESS) }
        var opts = UInt64(FSOPT_NOFOLLOW)
        if config.options.privateSize {
            al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
            opts |= UInt64(FSOPT_ATTR_CMN_EXTENDED)
        }

        while true {
            let count = getattrlistbulk(fd, &al, buf, DirReader.bufSize, opts)
            if count <= 0 {
                if count < 0 { out.stats.entryErrors += 1 }
                break
            }
            var entry = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                parseEntry(entry + 4, into: &out, claim: claim)
                entry += length
            }
        }
        return out
    }

    // Fields are packed in sys/attr.h bit order; ERROR comes right after RETURNED_ATTRS.
    @inline(__always)
    private func parseEntry(_ start: UnsafeRawPointer, into out: inout DirOutcome,
                            claim: (UInt64, Int64, Int64, UnsafePointer<CChar>?) -> Bool?) {
        var f = start
        let returned = f.loadUnaligned(as: attribute_set_t.self)
        f += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let err = f.loadUnaligned(as: UInt32.self)
            f += 4
            if err != 0 { out.stats.entryErrors += 1; return }
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

        if type == UInt32(VDIR.rawValue) {
            if dev != config.rootDev && !config.options.crossDevices { out.stats.mountsSkipped += 1; return }
            if flags & UInt32(SF_DATALESS) != 0 { out.stats.datalessDirs += 1; return }
            if let namePtr {
                let name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
                if access & UInt32(R_OK | X_OK) != UInt32(R_OK | X_OK) { out.deniedChildDirs.append(name) }
                out.childDirs.append(name)
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
        if fileAttrs & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            alloc = f.loadUnaligned(as: Int64.self)
            f += 8
        }
        var logical: Int64 = 0
        if fileAttrs & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            logical = f.loadUnaligned(as: Int64.self)
            f += 8
        }
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
            alloc = f.loadUnaligned(as: Int64.self)
            f += 8
        }

        if flags & UInt32(SF_DATALESS) != 0 {
            out.stats.datalessLogical += logical
            out.files += 1
            return
        }
        if links > 1 && type == UInt32(VREG.rawValue) {
            switch claim(fileID, alloc, logical, namePtr?.assumingMemoryBound(to: CChar.self)) {
            case nil:
                out.deferredLinks.append((fileID, alloc, logical))
                return
            case false?:
                out.stats.hardlinkDupes += 1
                return
            case true?:
                break
            }
        }
        out.alloc += alloc
        out.logical += logical
        out.files += 1
    }
}
