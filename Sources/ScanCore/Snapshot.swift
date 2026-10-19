import Darwin
import Foundation

/// Binary on-disk copy of a `DiskTree`, so the next launch starts from the last scan
/// and only replays FSEvents instead of walking the disk again.
public enum Snapshot {
    // Little-endian on disk: the file starts with the bytes "1ZTM" (31 5A 54 4D).
    private static let magic: UInt32 = 0x4D54_5A31
    /// 3: one flags byte per directory (bit 0: unreadable; bit 1, from 6: incomplete) after the parent id.
    /// 4: `uncertainBytes` (i64) in the header after `scanStart`.
    /// 5: firmlink aliases after `rootPath`; `ownCloneAware` (i64) per directory after `ownFiles`; `cloneAware` (i64)
    /// per hard-link entry; the clone-family table at the end.
    /// 6: byte 8 is the mode byte (bit 0 `privateSize`, bit 1 `crossDevices`); after the aliases the body is a list of
    /// sections (`Section`), each `tag u32 | size u64 | payload`, ended by tag 0; adds the skipped mount points.
    /// Later additions without a version bump: the optional `stats` section (#15), the optional `fileIDs` section (#49).
    /// Directory names that are not UTF-8 go in a must-understand section (`rawNames`), present only when there are any.
    /// Older versions are not read: a full scan rebuilds what they lack.
    private static let version: UInt32 = 6

    /// Body sections of format 6. Each payload must be read exactly to its end. A reader skips an unknown tag without
    /// the `mustUnderstand` bit (optional data added later, such as the full scan's statistics) and rejects the file
    /// for an unknown tag with it (data a reader must not ignore). `nodes` comes first, as the others refer to its ids.
    /// Every known section appears exactly once.
    enum Section: UInt32 {
        case end = 0
        case nodes = 1
        case hardlinks = 2
        case cloneFamilies = 3
        case mountPoints = 4
        /// Optional: the last full scan's `ScanStats` (8 × i64 in `ScanStats.merge` order) and its start, i64 ns.
        /// Without it the tree has no last-known counters (`DiskTree.fullScanStart == nil`). At least 72 bytes: values a
        /// later writer appends are skipped.
        case stats = 5
        /// Raw bytes of directory names that are not valid UTF-8 (`DiskTree.rawNames`); written only when there are
        /// any. Must be understood: without it those directories could not be opened again.
        case rawNames = 0x8000_0006
        /// Optional: `DirNode.fileID` of every node (count u32, equal to the node count; then u64 per node in id order).
        /// Written when any node has one. A file without it loads with `fileID = 0` everywhere: no identity check until
        /// the next read of the folder (chapter 03 §6.5).
        case fileIDs = 7
        static let mustUnderstand: UInt32 = 0x8000_0000
    }

    /// Header byte 8: bit 0 `privateSize`, bit 1 `crossDevices`, other bits 0. A snapshot is used only in its own mode.
    static func modeByte(privateSize: Bool, crossDevices: Bool) -> UInt8 {
        (privateSize ? 1 : 0) | (crossDevices ? 2 : 0)
    }

    /// The snapshot of `rootPath` (the resolved root) scanned in one mode: one file per root and mode, so that runs in
    /// different modes (`--private`) keep their own snapshots. Name: FNV-1a 64 of the root path's UTF-8 bytes, a NUL
    /// byte and the mode byte, as lowercase hex without leading zeros, + `.bin` (chapter 03 §6.1).
    /// - Parameter directory: where snapshots live; the default is `FIL_SNAPSHOT_DIR` or the user's cache folder.
    public static func url(
        for rootPath: String, privateSize: Bool = false, crossDevices: Bool = false,
        in directory: URL? = nil
    ) -> URL {
        // FNV-1a: stable across runs, unlike Hasher. NUL cannot occur in a path, so no two keys share their bytes.
        var h = fnv1a(rootPath.utf8)
        for b in [0, modeByte(privateSize: privateSize, crossDevices: crossDevices)] { h = (h ^ UInt64(b)) &* fnvPrime }
        return (directory ?? Self.directory).appendingPathComponent(String(h, radix: 16) + ".bin")
    }

    static func url(for tree: DiskTree, in directory: URL?) -> URL {
        url(for: tree.rootPath, privateSize: tree.privateSize, crossDevices: tree.crossDevices, in: directory)
    }

    /// Name used up to #33: the root path alone, shared by every mode. `load` removes such a file when it finds no
    /// snapshot under the new name (once per root, as the full scan that follows writes the new one).
    static func legacyURL(for rootPath: String, in directory: URL?) -> URL {
        (directory ?? Self.directory).appendingPathComponent(String(fnv1a(rootPath.utf8), radix: 16) + ".bin")
    }

    private static let fnvPrime: UInt64 = 0x100_0000_01b3
    private static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { h = (h ^ UInt64(b)) &* fnvPrime }
        return h
    }

    /// `FIL_SNAPSHOT_DIR` overrides the default cache location (used by tests).
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["FIL_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vucod.Fil/snapshots", isDirectory: true)
    }

    // Header layout: magic u32 | version u32 | mode u8 | rootDev i32 | eventId u64 | scanStart i64 |
    // uncertainBytes i64 | volumeUUID | rootPath | aliases | sections (nodes, hard links, clone families,
    // mount points, folder identities if known, stats if known, raw names if any, end). Chapter 03 §6.2 and §6.5.
    private static let eventIdOffset = 13

    /// Records a new event id and scan start in an existing snapshot without rewriting the tree.
    /// Valid only when the tree is unchanged since it was loaded or saved. Returns false if the file
    /// is missing or not ours, or an update changed the tree (a mount or unmount changes it without an event);
    /// the caller then does a full `save`.
    public static func advance(_ tree: DiskTree, in directory: URL? = nil) -> Bool {
        guard !tree.changedSinceSave else { return false }
        let fd = open(url(for: tree, in: directory).path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var head = [UInt8](repeating: 0, count: eventIdOffset)
        guard pread(fd, &head, head.count, 0) == head.count else { return false }
        var w = Writer()
        defer { w.free() }
        w.put(magic)
        w.put(version)
        w.put(modeByte(privateSize: tree.privateSize, crossDevices: tree.crossDevices))
        guard Array(w.bytes) == Array(head[0..<9]) else { return false }
        var f = Writer()
        defer { f.free() }
        f.put(tree.eventId)
        f.put(tree.scanStart)
        // One 16-byte pwrite inside the first page: no temp file, no copy of the tree.
        let field = f.bytes
        return pwrite(fd, field.baseAddress, field.count, off_t(eventIdOffset)) == field.count
    }

    /// The tree is owned by this call until it returns (`DiskTree` concurrent access).
    public static func save(_ tree: DiskTree, in directory: URL? = nil) throws {
        tree.acquire("Snapshot.save")
        defer { tree.release() }
        var t = Timings.Lap("save")
        tree.compact()
        t.lap("compact")
        let table = tree.hardlinks.table
        let clones = tree.clones.table
        // Names average well under 20 bytes; the buffer grows if the estimate is short.
        var w = Writer(capacity: 1024 + tree.nodes.count * 68 + table.count * 48 + clones.count * 32)
        w.put(magic)
        w.put(version)
        w.put(modeByte(privateSize: tree.privateSize, crossDevices: tree.crossDevices))
        w.put(Int32(tree.rootDev))
        w.put(tree.eventId)
        w.put(tree.scanStart)
        w.put(tree.uncertainBytes)
        w.put(tree.volumeUUID)
        w.put(tree.rootPath)
        w.put(UInt32(tree.aliases.count))
        for a in tree.aliases {
            w.put(a.dataPath)
            w.put(a.source)
        }

        var section = w.begin(.nodes)
        w.put(UInt32(tree.nodes.count))
        for n in tree.nodes {
            w.put(n.parent)
            w.put(UInt8(n.unreadable ? 1 : 0) | UInt8(n.incomplete ? 2 : 0))
            w.put(n.ownAlloc)
            w.put(n.ownLogical)
            w.put(n.ownFiles)
            w.put(n.ownCloneAware)
            w.put(n.name)
        }
        w.end(section)

        section = w.begin(.hardlinks)
        w.put(UInt32(table.count))
        for (inode, e) in table {
            w.put(inode)
            w.put(e.owner)
            w.put(e.alloc)
            w.put(e.logical)
            w.put(e.cloneAware)
            w.put(UInt32(e.others.count))
            for d in e.others { w.put(d) }
        }
        w.end(section)

        section = w.begin(.cloneFamilies)
        w.put(UInt32(clones.count))
        for (cid, e) in clones {
            w.put(cid)
            w.put(e.owner)
            w.put(e.original)
            w.put(e.alloc)
            w.put(UInt32(e.others.count))
            for d in e.others { w.put(d) }
        }
        w.end(section)

        section = w.begin(.mountPoints)
        w.put(UInt32(tree.mountPoints.count))
        for m in tree.mountPoints {
            w.put(m.parent)
            w.put(m.name)
        }
        w.end(section)

        if tree.nodes.contains(where: { $0.fileID != 0 }) {
            section = w.begin(.fileIDs)
            w.put(UInt32(tree.nodes.count))
            for n in tree.nodes { w.put(n.fileID) }
            w.end(section)
        }

        if let fullScanStart = tree.fullScanStart {
            section = w.begin(.stats)
            for v in tree.stats.stored { w.put(v) }
            w.put(fullScanStart)
            w.end(section)
        }

        if !tree.rawNames.isEmpty {
            section = w.begin(.rawNames)
            w.put(UInt32(tree.rawNames.count))
            for (id, bytes) in tree.rawNames {
                w.put(id)
                w.put(UInt32(bytes.count))
                for b in bytes { w.put(b) }
            }
            w.end(section)
        }

        w.put(Section.end.rawValue)
        w.put(UInt64(0))
        t.lap("encode(\(w.count) bytes)")
        let data = w.takeData()
        let url = url(for: tree, in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        tree.changedSinceSave = false
        t.lap("write")
    }

    /// Why `load` found no usable snapshot (chapter 03 §6.4). The caller then does a full scan.
    public enum LoadFailure: Error, Equatable, Sendable, CustomStringConvertible {
        /// No file for this root and mode (`ENOENT`).
        case missing
        /// The file exists but cannot be opened or mapped (`EACCES`, `EIO`, ...).
        case unreadable(errno: Int32)
        /// The file does not start with the snapshot magic.
        case notSnapshot
        /// Another format version (older ones are never read: a full scan rebuilds what they lack).
        case otherVersion(UInt32)
        /// Written for another scan mode (`--private`, device crossing).
        case otherMode
        /// Written for another root (a file-name hash collision).
        case otherRoot
        /// Truncated, or a table or section that breaks the format's rules.
        case corrupt

        public var description: String {
            switch self {
            case .missing: "missing"
            case .unreadable(let e): "unreadable (\(String(cString: strerror(e))))"
            case .notSnapshot: "not a snapshot"
            case .otherVersion(let v): "other version \(v)"
            case .otherMode: "other mode"
            case .otherRoot: "other root"
            case .corrupt: "corrupt"
            }
        }
    }

    /// The file mapped read-only. `missing` only when it does not exist; any other error keeps its errno. A file too
    /// short to hold the magic is `corrupt` (a write that stopped early), not another kind of file.
    private static func map(_ path: String) -> Result<Data, LoadFailure> {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .missing : .unreadable(errno: errno)) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.unreadable(errno: errno)) }
        let size = Int(st.st_size)
        guard size >= MemoryLayout.size(ofValue: magic) else { return .failure(.corrupt) }
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            return .failure(.unreadable(errno: errno))
        }
        return .success(Data(bytesNoCopy: p, count: size, deallocator: .custom { p, n in munmap(p, n) }))
    }

    /// The snapshot of `rootPath` in the mode of `options`, never a partial tree.
    public static func load(
        rootPath: String, options: ScanOptions,
        in directory: URL? = nil
    ) -> Result<DiskTree, LoadFailure> {
        load(rootPath: rootPath, privateSize: options.privateSize, crossDevices: options.crossDevices, in: directory)
    }

    /// The snapshot of `rootPath` in the given mode, never a partial tree.
    public static func load(
        rootPath: String, privateSize: Bool, crossDevices: Bool = false,
        in directory: URL? = nil
    ) -> Result<DiskTree, LoadFailure> {
        var t = Timings.Lap("load")
        let url = url(for: rootPath, privateSize: privateSize, crossDevices: crossDevices, in: directory)
        let data: Data
        switch map(url.path) {
        case .failure(let why):
            // The snapshot under the name of before #33 is never read again: drop it rather than leave it in the cache.
            if why == .missing { unlink(legacyURL(for: rootPath, in: directory).path) }
            return .failure(why)
        case .success(let d): data = d
        }
        return data.withUnsafeBytes { raw -> Result<DiskTree, LoadFailure> in
            var r = Reader(raw)
            guard r.get(UInt32.self) == magic else { return .failure(.notSnapshot) }
            let fileVersion = r.get(UInt32.self)
            let mode = r.get(UInt8.self)
            guard r.ok else { return .failure(.corrupt) }
            guard fileVersion == version else { return .failure(.otherVersion(fileVersion)) }
            guard mode == modeByte(privateSize: privateSize, crossDevices: crossDevices) else {
                return .failure(.otherMode)
            }
            let dev = dev_t(r.get(Int32.self))
            let eventId = r.get(UInt64.self)
            let scanStart = r.get(Int64.self)
            let uncertainBytes = r.get(Int64.self)
            let uuid = r.getString()
            let storedRoot = r.getString()
            guard r.ok else { return .failure(.corrupt) }
            guard storedRoot == rootPath else { return .failure(.otherRoot) }
            let aliasCount = Int(r.get(UInt32.self))
            guard r.ok, aliasCount <= (raw.count - r.offset) / 8 else { return .failure(.corrupt) }
            var aliases: [FirmlinkTable.Alias] = []
            for _ in 0..<aliasCount {
                aliases.append(FirmlinkTable.Alias(dataPath: r.getString(), source: r.getString()))
            }

            var nodes: [DirNode] = []
            var table: [UInt64: HardlinkRegistry.Entry] = [:]
            var families: [UInt64: CloneRegistry.Entry] = [:]
            // A loaded tree is about to be updated: the registries' per-directory indexes are collected while their
            // tables are decoded, so that an update's `forget` touches only the directories it re-reads.
            var linkPairs: [(dir: Int32, key: UInt64)] = []
            var familyPairs: [(dir: Int32, key: UInt64)] = []
            var mountPoints: [MountPoint] = []
            var stats: (ScanStats, start: Int64)?
            var rawNames: [Int32: [UInt8]] = [:]
            var seen = Set<UInt32>()
            while true {
                let tag = r.get(UInt32.self)
                let size = r.get(UInt64.self)
                guard r.ok, size <= UInt64(raw.count - r.offset) else { return .failure(.corrupt) }
                let sectionEnd = r.offset + Int(size)
                if tag == Section.end.rawValue { break }
                guard seen.insert(tag).inserted else { return .failure(.corrupt) }
                guard let section = Section(rawValue: tag) else {
                    // Optional data of a later writer is skipped; data it marks as required rejects the file.
                    guard tag & Section.mustUnderstand == 0 else { return .failure(.corrupt) }
                    r.offset = sectionEnd
                    continue
                }
                // The other sections refer to node ids.
                guard section == .nodes || !nodes.isEmpty else { return .failure(.corrupt) }
                let ok: Bool
                switch section {
                case .nodes: ok = r.getNodes(into: &nodes)
                case .hardlinks: ok = r.getHardlinks(into: &table, pairs: &linkPairs, nodeCount: nodes.count)
                case .cloneFamilies:
                    ok = r.getCloneFamilies(into: &families, pairs: &familyPairs, nodeCount: nodes.count)
                case .mountPoints: ok = r.getMountPoints(into: &mountPoints, nodeCount: nodes.count)
                case .stats:
                    // At least the 9 values known today; a later writer may append counters, which are skipped.
                    guard size >= 72 else { return .failure(.corrupt) }
                    let v = (0..<8).map { _ in r.get(Int64.self) }
                    stats = (ScanStats(stored: v), r.get(Int64.self))
                    ok = r.ok
                    r.offset = sectionEnd
                case .rawNames: ok = r.getRawNames(into: &rawNames, nodeCount: nodes.count)
                case .fileIDs: ok = r.getFileIDs(into: &nodes)
                case .end: ok = false
                }
                guard ok, r.ok, r.offset == sectionEnd else { return .failure(.corrupt) }
                t.lap("\(section)")
            }
            let required: [Section] = [.nodes, .hardlinks, .cloneFamilies, .mountPoints]
            guard r.ok, required.allSatisfy({ seen.contains($0.rawValue) }) else { return .failure(.corrupt) }
            let tree = DiskTree(
                rootPath: rootPath, rootDev: dev, privateSize: privateSize, crossDevices: crossDevices,
                nodes: nodes, eventId: eventId, volumeUUID: uuid, scanStart: scanStart,
                hardlinks: HardlinkRegistry(table, index: RegistryIndex(pairs: linkPairs)),
                clones: CloneRegistry(families, index: RegistryIndex(pairs: familyPairs)), aliases: aliases,
                mountPoints: mountPoints)
            tree.uncertainBytes = max(uncertainBytes, 0)
            tree.stats = stats?.0 ?? ScanStats()
            tree.fullScanStart = stats?.start
            tree.rawNames = rawNames
            tree.computeTotals()
            t.lap("computeTotals")
            return .success(tree)
        }
    }
}

/// Little-endian writer into one growing malloc'd buffer: no per-field `Data` appends.
private struct Writer {
    private(set) var base: UnsafeMutableRawPointer
    private(set) var count = 0
    private var capacity: Int

    init(capacity: Int = 64) {
        self.capacity = max(capacity, 64)
        base = malloc(self.capacity)!
    }

    private mutating func reserve(_ n: Int) {
        guard count + n > capacity else { return }
        capacity = max(capacity * 2, count + n)
        base = realloc(base, capacity)!
    }

    mutating func put<T: FixedWidthInteger>(_ v: T) {
        reserve(MemoryLayout<T>.size)
        base.storeBytes(of: v.littleEndian, toByteOffset: count, as: T.self)
        count += MemoryLayout<T>.size
    }

    mutating func put(_ s: String) {
        var s = s
        s.withUTF8 { bytes in
            put(UInt32(bytes.count))
            reserve(bytes.count)
            if let src = bytes.baseAddress { (base + count).copyMemory(from: src, byteCount: bytes.count) }
            count += bytes.count
        }
    }

    /// Writes a section header whose size `end` fills in; returns where the size goes.
    mutating func begin(_ section: Snapshot.Section) -> Int {
        put(section.rawValue)
        let at = count
        put(UInt64(0))
        return at
    }

    /// Sets the size of the section begun at `sizeOffset` to the bytes written since.
    func end(_ sizeOffset: Int) {
        let size = UInt64(count - sizeOffset - 8)
        (base + sizeOffset).storeBytes(of: size.littleEndian, as: UInt64.self)
    }

    var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: count) }

    /// Hands the buffer to a `Data` that frees it; the writer must not be used afterwards.
    func takeData() -> Data {
        Data(bytesNoCopy: base, count: count, deallocator: .free)
    }

    func free() { Darwin.free(base) }
}

private struct Reader {
    let raw: UnsafeRawBufferPointer
    var offset = 0
    var ok = true

    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    mutating func get<T: FixedWidthInteger>(_: T.Type) -> T {
        let size = MemoryLayout<T>.size
        guard ok, offset + size <= raw.count else { ok = false; return 0 }
        defer { offset += size }
        return T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    /// One directory record with a single bounds check for its fixed part.
    mutating func getNode() -> DirNode? {
        guard ok, offset + 41 <= raw.count else { ok = false; return nil }
        let p = raw.baseAddress! + offset
        var n = DirNode(parent: Int32(littleEndian: p.loadUnaligned(as: Int32.self)), name: "")
        let flags = p.load(fromByteOffset: 4, as: UInt8.self)
        n.unreadable = flags & 1 != 0
        n.incomplete = flags & 2 != 0
        n.ownAlloc = Int64(littleEndian: p.loadUnaligned(fromByteOffset: 5, as: Int64.self))
        n.ownLogical = Int64(littleEndian: p.loadUnaligned(fromByteOffset: 13, as: Int64.self))
        n.ownFiles = Int64(littleEndian: p.loadUnaligned(fromByteOffset: 21, as: Int64.self))
        n.ownCloneAware = Int64(littleEndian: p.loadUnaligned(fromByteOffset: 29, as: Int64.self))
        let len = Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 37, as: UInt32.self)))
        offset += 41
        guard offset + len <= raw.count else { ok = false; return nil }
        n.name = String(decoding: UnsafeRawBufferPointer(start: p + 41, count: len), as: UTF8.self)
        offset += len
        return n
    }

    /// Fixed part of a record: parent i32, flags u8, ownAlloc i64, ownLogical i64, ownFiles i64, ownCloneAware i64,
    /// name length u32. Node 0 is the root (parent -1); every other parent is an earlier node (no dead nodes).
    mutating func getNodes(into nodes: inout [DirNode]) -> Bool {
        let count = Int(get(UInt32.self))
        // Every record takes at least 41 bytes: a corrupt count must not drive the allocation below.
        guard ok, count > 0, count <= (raw.count - offset) / 41 else { return false }
        // Headroom for the directories the next updates append.
        nodes.reserveCapacity(count + count / 16 + 1024)
        for i in 0..<count {
            guard let n = getNode(), i == 0 ? n.parent == -1 : (n.parent >= 0 && Int(n.parent) < i) else {
                return false
            }
            nodes.append(n)
        }
        return true
    }

    /// inode u64, owner i32, alloc i64, logical i64, cloneAware i64, others count u32, others i32 × n.
    /// `pairs` gets (directory, inode) for the owner and each other directory (`RegistryIndex`).
    mutating func getHardlinks(
        into table: inout [UInt64: HardlinkRegistry.Entry], pairs: inout [(dir: Int32, key: UInt64)],
        nodeCount count: Int
    ) -> Bool {
        let linkCount = Int(get(UInt32.self))
        guard ok, linkCount <= (raw.count - offset) / 40 else { return false }
        table.reserveCapacity(linkCount)
        pairs.reserveCapacity(linkCount * 2)
        for _ in 0..<linkCount {
            let inode = get(UInt64.self)
            var e = HardlinkRegistry.Entry(
                owner: get(Int32.self), alloc: get(Int64.self),
                logical: get(Int64.self), cloneAware: get(Int64.self))
            let others = Int(get(UInt32.self))
            guard ok, e.owner >= 0, e.owner < count, others <= count, others <= (raw.count - offset) / 4 else {
                return false
            }
            for _ in 0..<others { e.others.append(get(Int32.self)) }
            guard ok, e.others.allSatisfy({ $0 >= 0 && $0 < count }) else { return false }
            pairs.append((e.owner, inode))
            for d in e.others { pairs.append((d, inode)) }
            table[inode] = e
        }
        return true
    }

    /// cloneID u64, owner i32, original i32 (-1 if unknown), alloc i64, others count u32, others i32 × n.
    /// `pairs` gets (directory, clone id) for the owner, the original's directory and each other directory.
    mutating func getCloneFamilies(
        into families: inout [UInt64: CloneRegistry.Entry], pairs: inout [(dir: Int32, key: UInt64)],
        nodeCount count: Int
    ) -> Bool {
        let cloneCount = Int(get(UInt32.self))
        guard ok, cloneCount <= (raw.count - offset) / 28 else { return false }
        families.reserveCapacity(cloneCount)
        pairs.reserveCapacity(cloneCount * 2)
        for _ in 0..<cloneCount {
            let cid = get(UInt64.self)
            var e = CloneRegistry.Entry(owner: get(Int32.self), original: get(Int32.self), alloc: get(Int64.self))
            let others = Int(get(UInt32.self))
            guard ok, e.owner >= 0, e.owner < count, e.original >= -1, e.original < count,
                others <= (raw.count - offset) / 4
            else { return false }
            e.others.reserveCapacity(others)
            for _ in 0..<others { e.others.append(get(Int32.self)) }
            guard ok, e.others.allSatisfy({ $0 >= 0 && $0 < count }) else { return false }
            pairs.append((e.owner, cid))
            if e.original >= 0 && e.original != e.owner { pairs.append((e.original, cid)) }
            for d in e.others where d != e.original { pairs.append((d, cid)) }
            families[cid] = e
        }
        return true
    }

    /// parent i32, name string (not empty).
    mutating func getMountPoints(into mountPoints: inout [MountPoint], nodeCount count: Int) -> Bool {
        let n = Int(get(UInt32.self))
        guard ok, n <= (raw.count - offset) / 8 else { return false }
        for _ in 0..<n {
            let parent = get(Int32.self)
            let name = getString()
            guard ok, parent >= 0, parent < count, !name.isEmpty else { return false }
            mountPoints.append(MountPoint(parent: parent, name: name))
        }
        return true
    }

    /// count u32 (the node count), then u64 per node in id order.
    mutating func getFileIDs(into nodes: inout [DirNode]) -> Bool {
        let n = Int(get(UInt32.self))
        guard ok, n == nodes.count, n <= (raw.count - offset) / 8 else { return false }
        let base = raw.baseAddress! + offset
        for i in 0..<n {
            nodes[i].fileID = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
        }
        offset += n * 8
        return true
    }

    /// id i32 (not the root), length u32 (not 0), bytes.
    mutating func getRawNames(into names: inout [Int32: [UInt8]], nodeCount count: Int) -> Bool {
        let n = Int(get(UInt32.self))
        guard ok, n <= (raw.count - offset) / 9 else { return false }
        for _ in 0..<n {
            let id = get(Int32.self)
            let len = Int(get(UInt32.self))
            guard ok, id > 0, id < count, len > 0, offset + len <= raw.count else { return false }
            names[id] = Array(UnsafeRawBufferPointer(rebasing: raw[offset..<offset + len]))
            offset += len
        }
        return true
    }

    mutating func getString() -> String {
        let len = Int(get(UInt32.self))
        guard ok, offset + len <= raw.count else { ok = false; return "" }
        defer { offset += len }
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + len]), as: UTF8.self)
    }
}
