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
/// directory where a member was seen. See docs/specs/accounting.md.
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
    private var hasOrphans = false
    /// Families created during an incremental update by a member that is not the original; see `takeCreated`.
    private var created: [UInt64]?

    init(_ table: [UInt64: Entry] = [:]) { self.table = table }

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
                counted += m.alloc
                owned += 1
                continue
            }
            if m.isOriginal { table.values[i].original = dir }
            let owner = table.values[i].owner
            if owner == dir { continue }
            if owner < 0 {
                table.values[i].owner = dir
                table.values[i].alloc = m.alloc
                if !table.values[i].others.isEmpty { table.values[i].others.removeAll { $0 == dir } }
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

    /// Incremental only: starts recording families created by a non-original member (`takeCreated`).
    func beginUpdate() {
        lock.lock()
        created = []
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
        table.values[i].original = dir
        guard previous != dir else { return nil }
        table.values[i].owner = dir
        table.values[i].others.removeAll { $0 == dir }
        if previous >= 0 { table.values[i].others.append(previous) }
        return previous >= 0 ? (previous, table.values[i].alloc) : nil
    }

    /// Drops every member recorded in a directory for which `shouldForget` is true (re-read or gone).
    func forget(where shouldForget: (Int32) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        var orphaned = false
        var gone: [UInt64] = []
        var i = table.startIndex
        while i != table.endIndex {
            let owner = table.values[i].owner
            if owner >= 0 && shouldForget(owner) { table.values[i].owner = -1 }
            let original = table.values[i].original
            if original >= 0 && shouldForget(original) { table.values[i].original = -1 }
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

    /// Gives every ownerless family to a live directory that still has a member (the original's first).
    /// Returns the sizes each new owner must now count.
    func resolveOrphans() -> [(dir: Int32, alloc: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard hasOrphans else { return [] }
        hasOrphans = false
        var moved: [(dir: Int32, alloc: Int64)] = []
        var gone: [UInt64] = []
        var i = table.startIndex
        while i != table.endIndex {
            if table.values[i].owner < 0 {
                let original = table.values[i].original
                let next = original >= 0 && table.values[i].others.contains(original) ? original : table.values[i].others.first
                if let next {
                    table.values[i].others.removeAll { $0 == next }
                    table.values[i].owner = next
                    moved.append((next, table.values[i].alloc))
                } else {
                    gone.append(table.keys[i])
                }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table[k] = nil }
        return moved
    }

    /// Moves each family to the directory holding its original when another directory owns it.
    /// Returns the moves; the caller shifts `alloc` from `from` to `to`.
    func preferOriginals() -> [(from: Int32, to: Int32, alloc: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        var moves: [(from: Int32, to: Int32, alloc: Int64)] = []
        var i = table.startIndex
        while i != table.endIndex {
            let e = table.values[i]
            if e.original >= 0 && e.owner >= 0 && e.owner != e.original {
                moves.append((e.owner, e.original, e.alloc))
                table.values[i].others.removeAll { $0 == e.original }
                table.values[i].others.append(e.owner)
                table.values[i].owner = e.original
            }
            table.formIndex(after: &i)
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
                    table.values[i].others = table.values[i].others.compactMap { map[Int($0)] >= 0 ? map[Int($0)] : nil }
                }
            }
            table.formIndex(after: &i)
        }
        for k in gone { table.removeValue(forKey: k) }
    }
}
