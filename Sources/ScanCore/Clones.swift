import Darwin
import Foundation

/// A file that shares all of its blocks with other files (`EF_SHARES_ALL_BLOCKS`): an APFS full clone.
/// All members of a clone family have the same `cloneID` (ATTR_CMNEXT_CLONEID) and the same allocated size.
struct CloneMember {
    let cloneID: UInt64
    let alloc: Int64
    /// The file the family was cloned from: its file id is the clone id.
    let isOriginal: Bool
}

/// Counts each APFS clone family once in the clone-aware size, like `HardlinkRegistry` counts each inode once.
/// Per family it keeps the directory that counts (owns) it, its size, the directory holding the original file
/// (preferred owner, so attribution does not depend on the order workers read directories), and every other
/// directory where a member was seen. See docs/design/02-size-accounting.md.
final class CloneRegistry: @unchecked Sendable {
    struct Entry {
        /// Directory that counts this family; -1 while released and not yet re-claimed.
        var owner: Int32
        /// Directory holding the original file (file id == clone id), -1 if not seen.
        var original: Int32 = -1
        var alloc: Int64
        /// Other directories where a member was seen (never contains `owner`; may repeat for large families).
        var others: [Int32] = []
    }

    private let lock = NSLock()
    private(set) var table: [UInt64: Entry]
    /// Per directory, the families it owns, holds the original of, or has a member in, so that `forget` touches only
    /// the directories it is given. Nil until `buildIndex`; then kept up to date. Stale or repeated keys are skipped.
    private var byDir: RegistryIndex?
    /// Ownerless families that still have members elsewhere; `resolveOrphans` settles them.
    private var orphans = Set<UInt64>()
    /// Families created during an incremental update by a member that is not the original; see `takeCreated`.
    private var created: [UInt64]?
    /// Incremental only: families whose owner or original changed in this update. Only these can have an owner other
    /// than their original, so `preferOriginals` looks at them instead of the table.
    private var touched: Set<UInt64>?

    init(_ table: [UInt64: Entry] = [:], index: RegistryIndex? = nil) {
        self.table = table
        byDir = index
    }

    /// Builds the per-directory index from the table, O(table); `Snapshot.load` hands one over instead, made while
    /// decoding (the same pairs: owner, original when it differs, others other than the original).
    func buildIndex() {
        lock.lock()
        defer { lock.unlock() }
        buildIndexLocked()
    }

    private func buildIndexLocked() {
        byDir = RegistryIndex { visit in
            for (cid, e) in table {
                if e.owner >= 0 { visit(e.owner, cid) }
                if e.original >= 0 && e.original != e.owner { visit(e.original, cid) }
                for d in e.others where d != e.original { visit(d, cid) }
            }
        }
    }

    /// Records the members found in `dir` (one directory read). Returns the bytes `dir` counts (the size of each
    /// family it now owns) and how many members were not counted because their family is counted already.
    func claim(_ members: [CloneMember], by dir: Int32) -> (bytes: Int64, dupes: Int) {
        guard !members.isEmpty else { return (0, 0) }
        lock.lock()
        defer { lock.unlock() }
        var counted: Int64 = 0
        var owned = 0
        for m in members {
            guard let i = table.index(forKey: m.cloneID) else {
                table[m.cloneID] = Entry(owner: dir, original: m.isOriginal ? dir : -1, alloc: m.alloc)
                if !m.isOriginal { created?.append(m.cloneID) }
                byDir?.add(m.cloneID, to: dir)
                touched?.insert(m.cloneID)
                counted += m.alloc
                owned += 1
                continue
            }
            if byDir != nil {
                // A key when the directory first appears in the entry; a repeated key is harmless.
                let e = table.values[i]
                if e.owner != dir && e.original != dir && e.others.last != dir { byDir?.add(m.cloneID, to: dir) }
            }
            if m.isOriginal {
                table.values[i].original = dir
                touched?.insert(m.cloneID)
            }
            let owner = table.values[i].owner
            if owner == dir { continue }
            if owner < 0 {
                table.values[i].owner = dir
                table.values[i].alloc = m.alloc
                if !table.values[i].others.isEmpty { table.values[i].others.removeAll { $0 == dir } }
                orphans.remove(m.cloneID)
                touched?.insert(m.cloneID)
                counted += m.alloc
                owned += 1
                continue
            }
            let others = table.values[i].others
            // Linear check only while small: a huge family may list a directory twice, which is harmless.
            if others.last != dir && (others.count > 64 || !others.contains(dir)) { table.values[i].others.append(dir) }
        }
        return (counted, members.count - owned)
    }

    /// Incremental only: starts recording families created by a non-original member (`takeCreated`) and the families
    /// whose owner or original changes (`preferOriginals`).
    func beginUpdate() {
        lock.lock()
        created = []
        touched = []
        lock.unlock()
    }

    /// Ends what `beginUpdate` started.
    func endUpdate() {
        lock.lock()
        created = nil
        touched = nil
        lock.unlock()
    }

    /// The families recorded since `beginUpdate`, and stops recording.
    func takeCreated() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        let out = created ?? []
        created = nil
        return out
    }

    func entry(_ cloneID: UInt64) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return table[cloneID]
    }

    /// Makes `dir` (holding the original, which it already counts as a plain file) the owner of `cloneID`.
    /// Returns the previous owner, which must stop counting the family's size.
    func adopt(_ cloneID: UInt64, by dir: Int32) -> (previous: Int32, alloc: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = table.index(forKey: cloneID) else { return nil }
        let previous = table.values[i].owner
        let e = table.values[i]
        if e.owner != dir && e.original != dir && !e.others.contains(dir) { byDir?.add(cloneID, to: dir) }
        table.values[i].original = dir
        touched?.insert(cloneID)
        guard previous != dir else { return nil }
        table.values[i].owner = dir
        table.values[i].others.removeAll { $0 == dir }
        if previous >= 0 { table.values[i].others.append(previous) }
        return previous >= 0 ? (previous, table.values[i].alloc) : nil
    }

    /// Drops every member recorded in `dirs` (each is re-read or gone). Touches only the families those directories
    /// hold (`byDir`), not the table.
    func forget(_ dirs: Set<Int32>) {
        guard !dirs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if byDir == nil { buildIndexLocked() }
        for d in dirs {
            byDir?.take(d) { cid in
                guard let i = table.index(forKey: cid) else { return }
                var hit = false
                if table.values[i].owner == d {
                    table.values[i].owner = -1
                    hit = true
                }
                if table.values[i].original == d {
                    table.values[i].original = -1
                    hit = true
                }
                if table.values[i].others.contains(d) {
                    table.values[i].others.removeAll { $0 == d }
                    hit = true
                }
                guard hit else { return }  // stale or repeated key
                touched?.insert(cid)
                guard table.values[i].owner < 0 else { return }
                if table.values[i].others.isEmpty {
                    table.remove(at: i)
                    orphans.remove(cid)
                } else {
                    orphans.insert(cid)
                }
            }
        }
    }

    /// Gives every ownerless family to a live directory that still has a member (the original's first).
    /// Returns the sizes each new owner must now count. Walks only the orphans, not the table.
    func resolveOrphans() -> [(dir: Int32, alloc: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard !orphans.isEmpty else { return [] }
        var moved: [(dir: Int32, alloc: Int64)] = []
        // In family order: the result does not depend on the set's iteration order.
        for cid in orphans.sorted() {
            guard let i = table.index(forKey: cid), table.values[i].owner < 0 else { continue }
            let original = table.values[i].original
            let next =
                original >= 0 && table.values[i].others.contains(original) ? original : table.values[i].others.first
            if let next {
                // `next` keeps its index key: it moves from `others` to `owner`.
                table.values[i].others.removeAll { $0 == next }
                table.values[i].owner = next
                touched?.insert(cid)
                moved.append((next, table.values[i].alloc))
            } else {
                table.remove(at: i)
            }
        }
        orphans.removeAll()
        return moved
    }

    /// Moves each family to the directory holding its original when another directory owns it.
    /// Returns the moves; the caller shifts `alloc` from `from` to `to`.
    /// During an update only the families touched since `beginUpdate` are looked at: every other one already had its
    /// original's directory as owner (or no original) when the previous scan or update ended.
    func preferOriginals() -> [(from: Int32, to: Int32, alloc: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        var moves: [(from: Int32, to: Int32, alloc: Int64)] = []
        func prefer(_ i: Dictionary<UInt64, Entry>.Index) {
            let e = table.values[i]
            if e.original >= 0 && e.owner >= 0 && e.owner != e.original {
                // Both directories keep their index keys: they only swap roles.
                moves.append((e.owner, e.original, e.alloc))
                table.values[i].others.removeAll { $0 == e.original }
                table.values[i].others.append(e.owner)
                table.values[i].owner = e.original
            }
        }
        if let touched {
            // In family order: the moves do not depend on the set's iteration order.
            for cid in touched.sorted() { if let i = table.index(forKey: cid) { prefer(i) } }
        } else {
            var i = table.startIndex
            while i != table.endIndex {
                prefer(i)
                table.formIndex(after: &i)
            }
        }
        return moves
    }

    /// Renumbers directories after `DiskTree.compact`; `map[old]` is the new id, or -1 for a dropped directory.
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
                let original = table.values[i].original
                table.values[i].original = original >= 0 ? map[Int(original)] : -1
                if !table.values[i].others.isEmpty {
                    table.values[i].others = table.values[i].others.compactMap {
                        map[Int($0)] >= 0 ? map[Int($0)] : nil
                    }
                }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table.removeValue(forKey: k) }
        // Every ownerless family was dropped above. The index is O(table) to renumber, like the table: rebuilt.
        orphans.removeAll()
        if byDir != nil { buildIndexLocked() }
    }
}
