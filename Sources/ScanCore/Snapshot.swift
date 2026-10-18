import Darwin
import Foundation

/// Binary on-disk copy of a `DiskTree`, so the next launch starts from the last scan
/// and only replays FSEvents instead of walking the disk again.
public enum Snapshot {
    private static let magic: UInt32 = 0x4D54_5A31 // "MTZ1"
    /// 3: one flags byte per directory (bit 0: unreadable) after the parent id.
    /// 4: `uncertainBytes` (i64) in the header after `scanStart`.
    /// 5: firmlink aliases after `rootPath`; `ownCloneAware` (i64) per directory after `ownFiles`; `cloneAware` (i64)
    /// per hard-link entry; the clone-family table at the end. Older versions are not read: a full scan
    /// rebuilds what they lack.
    private static let version: UInt32 = 5

    /// - Parameter directory: where snapshots live; the default is `FIL_SNAPSHOT_DIR` or the user's cache folder.
    public static func url(for rootPath: String, in directory: URL? = nil) -> URL {
        // FNV-1a of the root path: stable across runs, unlike Hasher.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in rootPath.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return (directory ?? Self.directory).appendingPathComponent(String(h, radix: 16) + ".bin")
    }

    /// `FIL_SNAPSHOT_DIR` overrides the default cache location (used by tests).
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["FIL_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vucod.Fil/snapshots", isDirectory: true)
    }

    // Header layout: magic u32 | version u32 | privateSize u8 | rootDev i32 | eventId u64 | scanStart i64 |
    // uncertainBytes i64 | volumeUUID | rootPath | aliases | nodes | hard links | clone families
    private static let eventIdOffset = 13

    /// Records a new event id and scan start in an existing snapshot without rewriting the tree.
    /// Valid only when the tree is unchanged since it was loaded or saved. Returns false if the file
    /// is missing or not ours; the caller then does a full `save`.
    public static func advance(_ tree: DiskTree, in directory: URL? = nil) -> Bool {
        let fd = open(url(for: tree.rootPath, in: directory).path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var head = [UInt8](repeating: 0, count: eventIdOffset)
        guard pread(fd, &head, head.count, 0) == head.count else { return false }
        var w = Writer()
        defer { w.free() }
        w.put(magic)
        w.put(version)
        w.put(UInt8(tree.privateSize ? 1 : 0))
        guard Array(w.bytes) == Array(head[0..<9]) else { return false }
        var f = Writer()
        defer { f.free() }
        f.put(tree.eventId)
        f.put(tree.scanStart)
        // One 16-byte pwrite inside the first page: no temp file, no copy of the tree.
        let field = f.bytes
        return pwrite(fd, field.baseAddress, field.count, off_t(eventIdOffset)) == field.count
    }

    public static func save(_ tree: DiskTree, in directory: URL? = nil) throws {
        var t = Timings.Lap("save")
        tree.compact()
        t.lap("compact")
        let table = tree.hardlinks.table
        let clones = tree.clones.table
        // Names average well under 20 bytes; the buffer grows if the estimate is short.
        var w = Writer(capacity: 1024 + tree.nodes.count * 60 + table.count * 48 + clones.count * 32)
        w.put(magic)
        w.put(version)
        w.put(UInt8(tree.privateSize ? 1 : 0))
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
        w.put(UInt32(tree.nodes.count))
        for n in tree.nodes {
            w.put(n.parent)
            w.put(UInt8(n.unreadable ? 1 : 0))
            w.put(n.ownAlloc)
            w.put(n.ownLogical)
            w.put(n.ownFiles)
            w.put(n.ownCloneAware)
            w.put(n.name)
        }
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
        w.put(UInt32(clones.count))
        for (cid, e) in clones {
            w.put(cid)
            w.put(e.owner)
            w.put(e.original)
            w.put(e.alloc)
            w.put(UInt32(e.others.count))
            for d in e.others { w.put(d) }
        }
        t.lap("encode(\(w.count) bytes)")
        let data = w.takeData()
        let url = url(for: tree.rootPath, in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        t.lap("write")
    }

    /// Returns nil if there is no usable snapshot (missing, other format, other scan mode).
    public static func load(rootPath: String, privateSize: Bool, in directory: URL? = nil) -> DiskTree? {
        var t = Timings.Lap("load")
        guard let data = try? Data(contentsOf: url(for: rootPath, in: directory), options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> DiskTree? in
            var r = Reader(raw)
            guard r.get(UInt32.self) == magic, r.get(UInt32.self) == version,
                  r.get(UInt8.self) == (privateSize ? 1 : 0) else { return nil }
            let dev = dev_t(r.get(Int32.self))
            let eventId = r.get(UInt64.self)
            let scanStart = r.get(Int64.self)
            let uncertainBytes = r.get(Int64.self)
            let uuid = r.getString()
            guard r.getString() == rootPath else { return nil }
            let aliasCount = Int(r.get(UInt32.self))
            guard r.ok, aliasCount <= (raw.count - r.offset) / 8 else { return nil }
            var aliases: [FirmlinkTable.Alias] = []
            for _ in 0..<aliasCount { aliases.append(FirmlinkTable.Alias(dataPath: r.getString(), source: r.getString())) }
            let count = Int(r.get(UInt32.self))
            // Every record takes at least 41 bytes: a corrupt count must not drive the allocation below.
            guard r.ok, count <= (raw.count - r.offset) / 41 else { return nil }
            var nodes: [DirNode] = []
            // Headroom for the directories the next updates append.
            nodes.reserveCapacity(count + count / 16 + 1024)
            for i in 0..<count {
                // Fixed part of a record: parent i32, flags u8, ownAlloc i64, ownLogical i64, ownFiles i64,
                // ownCloneAware i64, name length u32.
                guard let n = r.getNode(), i == 0 ? n.parent == -1 : (n.parent >= 0 && Int(n.parent) < i) else {
                    return nil
                }
                nodes.append(n)
            }
            t.lap("nodes(\(count))")
            let linkCount = Int(r.get(UInt32.self))
            var table: [UInt64: HardlinkRegistry.Entry] = [:]
            table.reserveCapacity(linkCount)
            for _ in 0..<linkCount {
                let inode = r.get(UInt64.self)
                var e = HardlinkRegistry.Entry(owner: r.get(Int32.self), alloc: r.get(Int64.self),
                                               logical: r.get(Int64.self), cloneAware: r.get(Int64.self))
                let others = Int(r.get(UInt32.self))
                guard r.ok, e.owner >= 0, e.owner < count, others <= count else { return nil }
                for _ in 0..<others { e.others.append(r.get(Int32.self)) }
                guard r.ok, e.others.allSatisfy({ $0 >= 0 && $0 < count }) else { return nil }
                table[inode] = e
            }
            guard r.ok, !nodes.isEmpty else { return nil }
            t.lap("hardlinks(\(linkCount))")
            let cloneCount = Int(r.get(UInt32.self))
            guard r.ok, cloneCount <= (raw.count - r.offset) / 24 else { return nil }
            var families: [UInt64: CloneRegistry.Entry] = [:]
            families.reserveCapacity(cloneCount)
            for _ in 0..<cloneCount {
                let cid = r.get(UInt64.self)
                var e = CloneRegistry.Entry(owner: r.get(Int32.self), original: r.get(Int32.self), alloc: r.get(Int64.self))
                let others = Int(r.get(UInt32.self))
                guard r.ok, e.owner >= 0, e.owner < count, e.original >= -1, e.original < count,
                      others <= (raw.count - r.offset) / 4 else { return nil }
                e.others.reserveCapacity(others)
                for _ in 0..<others { e.others.append(r.get(Int32.self)) }
                guard r.ok, e.others.allSatisfy({ $0 >= 0 && $0 < count }) else { return nil }
                families[cid] = e
            }
            guard r.ok else { return nil }
            t.lap("clones(\(cloneCount))")
            let tree = DiskTree(rootPath: rootPath, rootDev: dev, privateSize: privateSize, nodes: nodes,
                                eventId: eventId, volumeUUID: uuid, scanStart: scanStart, hardlinks: HardlinkRegistry(table),
                                clones: CloneRegistry(families), aliases: aliases)
            tree.uncertainBytes = max(uncertainBytes, 0)
            tree.computeTotals()
            t.lap("computeTotals")
            return tree
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
        n.unreadable = p.load(fromByteOffset: 4, as: UInt8.self) & 1 != 0
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

    mutating func getString() -> String {
        let len = Int(get(UInt32.self))
        guard ok, offset + len <= raw.count else { ok = false; return "" }
        defer { offset += len }
        return String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + len]), as: UTF8.self)
    }
}
