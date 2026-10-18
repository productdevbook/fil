import CoreServices
import Darwin
import Foundation
import Synchronization

public struct UpdateReport: Sendable {
    /// Events inside the tree delivered before the barrier (directory-level, so several changes may share one).
    public var events = 0
    public var dirsRead = 0  // directories re-read on their own (contents changed)
    public var subtreesScanned = 0  // new or flagged directories walked in full
    public var dirsRemoved = 0
    public var historyTime: Duration = .zero
    public var applyTime: Duration = .zero
    /// Tolerant mode: bytes this update added to `DiskTree.uncertainBytes`, and the first such files.
    public var uncertainBytes: Int64 = 0
    public var uncertainPaths: [String] = []
    /// Volumes found mounted on a folder of the tree, plus recorded mount points found unmounted (neither leaves an
    /// event in the history).
    public var mountChanges = 0
    /// What this update's re-reads and walks counted. `DiskTree.stats` keep the last full scan's counters.
    public var stats = ScanStats()

    /// The update read, walked or removed a directory: the tree may differ from the snapshot it was loaded from, so
    /// it must be saved (not `Snapshot.advance`d) and is not "up to date". False when every event fell outside the
    /// tree (the barrier's own folder, ...).
    public var treeChanged: Bool { dirsRead > 0 || subtreesScanned > 0 || dirsRemoved > 0 }
}

/// Why an incremental update was not possible; the caller then does a full scan.
/// After a failure the tree may be partly updated and must be discarded.
public enum UpdateFailure: Error, Sendable, CustomStringConvertible {
    /// The root cannot be examined (`lstat` failed) or, during the replay, listed.
    case rootUnreadable(errno: Int32)
    /// The root is now on another volume than the one the tree was scanned on.
    case volumeChanged(expected: String, found: String)
    /// FSEvents flagged the history as incomplete: names of the flags and the path they came with.
    case historyUntrusted(flags: [String], path: String)
    /// The history replay did not finish within its time limit.
    case historyTimeout(seconds: Int)
    /// The barrier event that closes the replay did not arrive in time.
    case barrierTimeout(seconds: Int)
    /// The FSEvents stream or its barrier directory could not be set up.
    case streamFailed(String)
    /// A file with several hard links, older than the tree, that the tree has no record of: it was counted
    /// somewhere as a single-link file. Paths of the first such files found.
    case unattributedHardLink(paths: [String])
    /// The firmlinks that decide which data-volume directories the tree skips differ from the snapshot's.
    case firmlinksChanged
    /// The root lies on the data volume and holds a firmlink's target below it (`/System/Volumes/Data` itself,
    /// `/System/Volumes/Data/usr`, ...). fseventsd reports changes there under the firmlink path (`/Users/...`,
    /// `/usr/local/...`), which is no spelling of the root, so an update would miss them and present stale sizes as
    /// current.
    case dataVolumeRoot

    public var description: String {
        switch self {
        case .rootUnreadable(let e): "root unreadable (\(String(cString: strerror(e))))"
        case .volumeChanged(let a, let b):
            "volume changed (\(a.isEmpty ? "unknown" : a) -> \(b.isEmpty ? "unknown" : b))"
        case .historyUntrusted(let flags, let path): "history untrusted (\(flags.joined(separator: ", ")) at \(path))"
        case .historyTimeout(let s): "history replay timed out after \(s) s"
        case .barrierTimeout(let s): "barrier event timed out after \(s) s"
        case .streamFailed(let why): "FSEvents stream failed: \(why)"
        case .unattributedHardLink(let paths):
            "unattributed hard link: \(paths.prefix(5).joined(separator: ", "))"
                + (paths.count > 5 ? " (+\(paths.count - 5) more)" : "")
        case .firmlinksChanged: "firmlinks changed"
        case .dataVolumeRoot:
            "incremental updates are not supported for a data-volume root that holds firmlinked folders"
        }
    }
}

/// Brings a saved `DiskTree` up to date by replaying FSEvents since its last scan,
/// re-reading only the directories that changed.
public enum Incremental {
    /// Fails when the history cannot be trusted (other volume, journal reset, dropped events, ...);
    /// the caller should then discard the tree and do a full scan.
    /// The tree is owned by this call until it returns (`DiskTree` concurrent access).
    public static func update(_ tree: DiskTree, options: ScanOptions = ScanOptions()) -> Result<
        UpdateReport, UpdateFailure
    > {
        tree.acquire("Incremental.update")
        defer { tree.release() }
        guard !options.firmlinks.holdsFirmlinkTargets(tree.rootPath) else { return .failure(.dataVolumeRoot) }
        Scanner.preventCloudDownloads()
        var st = stat()
        guard lstat(tree.rootPath, &st) == 0 else { return .failure(.rootUnreadable(errno: errno)) }
        let volume = Scanner.volumeUUID(st.st_dev)
        guard !tree.volumeUUID.isEmpty, volume == tree.volumeUUID else {
            return .failure(.volumeChanged(expected: tree.volumeUUID, found: volume))
        }
        // Device numbers are assigned at mount time and may differ after a reboot.
        tree.rootDev = st.st_dev
        guard options.firmlinks.aliases(for: tree.rootPath) == tree.aliases else { return .failure(.firmlinksChanged) }

        var report = UpdateReport()
        var t = Timings.Lap("update")
        let start = ContinuousClock.now
        // Before the barrier event is made, like in a full scan: later changes are replayed by the next update.
        let startWallClock = Scanner.nowNanoseconds()
        let history: EventHistory
        #if DEBUG
            let fetched = EventHistory.fetch(root: tree.rootPath, since: tree.eventId, faults: options.faults.history)
        #else
            let fetched = EventHistory.fetch(root: tree.rootPath, since: tree.eventId)
        #endif
        switch fetched {
        case .failure(let why): return .failure(why)
        case .success(let h): history = h
        }
        if Timings.enabled {
            for e in history.events {
                FileHandle.standardError.write(
                    Data("[timing] update.event \(e.mustScanSubDirs ? "(subdirs) " : "")\(e.path)\n".utf8))
            }
        }
        // Only changes inside the tree count. The stream also watches the barrier directory, and the creation and
        // removal of the previous barrier directories are reported on their parent, the temporary folder: one event
        // on almost every run that is not a change of the tree (unless the tree holds that folder).
        let prefixes = rootPrefixes(tree.rootPath, firmlinks: options.firmlinks)
        let events = history.events.filter {
            relativeComponents($0.path, prefixes: prefixes, aliases: tree.aliases) != nil
        }
        report.events = events.count
        report.historyTime = ContinuousClock.now - start
        t.lap("history(\(history.events.count) events, \(events.count) inside the tree)")

        let applyStart = ContinuousClock.now
        if let why = applyTracked(events, to: tree, options: options, report: &report) { return .failure(why) }
        t.lap("apply")
        if report.treeChanged { tree.changedSinceSave = true }
        tree.eventId = history.barrierId
        tree.scanStart = startWallClock
        if tree.hardlinks.unattributed {
            report.uncertainBytes = tree.hardlinks.unattributedAlloc
            report.uncertainPaths = tree.hardlinks.unattributedPaths
            tree.uncertainBytes += report.uncertainBytes
        }
        report.applyTime = ContinuousClock.now - applyStart
        return .success(report)
    }

    /// `apply` with the registries in update mode. Tests call it directly with chosen events.
    static func applyTracked(
        _ events: [EventHistory.Event], to tree: DiskTree, options: ScanOptions,
        report: inout UpdateReport
    ) -> UpdateFailure? {
        tree.hardlinks.beginUpdate(cutoff: tree.scanStart, strict: options.strictHardlinks)
        tree.hardlinks.trackDrift()
        tree.clones.beginUpdate()
        // The tree's counters stay those of the last full scan; what the re-reads count goes to the report.
        let fullScanStats = tree.stats
        tree.stats = ScanStats()
        defer {
            report.stats = tree.stats
            tree.stats = fullScanStats
            tree.hardlinks.endUpdate()
            _ = tree.hardlinks.takeDrift()
            _ = tree.clones.takeCreated()
        }
        return apply(events, to: tree, options: options, report: &report)
    }

    /// Replays `events` on `tree`. Work is proportional to the changed directories and their ancestors,
    /// not to the size of the tree: child lists are kept on the tree, totals are fixed up along ancestor chains.
    private static func apply(
        _ events: [EventHistory.Event], to tree: DiskTree, options: ScanOptions,
        report: inout UpdateReport
    ) -> UpdateFailure? {
        let prefixes = rootPrefixes(tree.rootPath, firmlinks: options.firmlinks)
        let aliases = tree.aliases
        // FSEvents keeps no Mount or Unmount event in its history (they are delivered live only), so a volume mounted
        // on a directory of the tree since the snapshot, or unmounted from a recorded mount point, is found in the
        // mount table.
        let mounts =
            options.crossDevices
            ? MountChanges()
            : mountChanges(tree, prefixes: prefixes, aliases: aliases, firmlinks: options.firmlinks)
        // A folder read only in part is read again on every update until a read is complete: the error may be gone
        // without any event. One pass over the flags; empty for almost every tree.
        let retry: [Int32] = tree.nodes.withUnsafeBufferPointer { nodes in
            var ids: [Int32] = []
            for i in nodes.indices where nodes[i].incomplete && !nodes[i].isDead { ids.append(Int32(i)) }
            return ids
        }
        guard !events.isEmpty || !mounts.mounted.isEmpty || !mounts.uncovered.isEmpty || !retry.isEmpty else {
            return nil
        }
        report.mountChanges = mounts.mounted.count + mounts.uncovered.count
        func unattributed() -> UpdateFailure { .unattributedHardLink(paths: tree.hardlinks.unattributedPaths) }
        var t = Timings.Lap("apply")
        let firstNew = tree.nodes.count
        tree.syncLinks()
        t.lap("links")

        // 1. Map each event to the nearest directory we know; a new directory is found by re-reading its parent.
        var full = Set<Int32>()
        var shallow = Set<Int32>()
        for e in events {
            guard let comps = relativeComponents(e.path, prefixes: prefixes, aliases: aliases) else { continue }
            var id: Int32 = 0
            for c in comps {
                guard let child = tree.child(of: id, named: String(c)) else { break }
                id = child
            }
            if e.mustScanSubDirs { full.insert(id) } else { shallow.insert(id) }
        }
        // Its old contents are hidden now; the rescan's own-device check finds the other volume and removes the node.
        full.formUnion(mounts.mounted)
        // The folder under an unmounted volume is visible again: its parent's re-read finds it as a new directory.
        shallow.formUnion(mounts.uncovered)
        // A flagged folder whose own path is gone (renamed or removed) is dropped by its re-read; its parent is read
        // too, so that the folder under its new name is found.
        for id in retry {
            shallow.insert(id)
            if id != 0 && !stillDirectory(id, in: tree) { shallow.insert(tree.nodes[Int(id)].parent) }
        }
        func underFull(_ id: Int32, includingSelf: Bool) -> Bool {
            var i = includingSelf ? id : tree.nodes[Int(id)].parent
            while i >= 0 {
                if full.contains(i) { return true }
                i = tree.nodes[Int(i)].parent
            }
            return false
        }
        shallow = shallow.filter { !underFull($0, includingSelf: true) }
        full = full.filter { $0 == 0 || !underFull($0, includingSelf: false) }
        t.lap("map(\(shallow.count) shallow, \(full.count) full)")

        // 2. Re-read changed directories in parallel, then apply the results in id order.
        // Hard links are claimed only after their old records are dropped.
        let reread = shallow.sorted()
        let outcomes = readDirectories(
            reread.map { tree.path(of: Int($0)) }, cPaths: reread.map { tree.cPath(of: Int($0)) },
            tree: tree, options: options)
        report.dirsRead += reread.count
        t.lap("reread(\(reread.count))")
        if options.strictHardlinks && tree.hardlinks.unattributed { return unattributed() }

        var changed: [Int32] = []  // own sizes or children changed; totals are fixed up from here
        var killRoots: [Int32] = []
        var unreadable: [Int32] = []  // kept, but a full scan would not know what is inside
        var readable: [Int32] = []  // unreadable children that can be listed again
        var newDirs: [Int32] = []
        var pendingLinks: [(dir: Int32, inode: UInt64, alloc: Int64, logical: Int64, cloneAware: Int64)] = []
        var pendingClones: [(dir: Int32, members: [CloneMember])] = []
        var newMounts: [MountPoint] = []
        for (id, out) in zip(reread, outcomes) {
            guard out.opened else {
                if id == 0 { return .rootUnreadable(errno: out.openError) }
                // A raw name that does not open by its bytes may still exist: kept unreadable, like a full scan keeps it.
                if out.isGone && !(out.openError != EXDEV && tree.rawNames[id] != nil) {
                    if out.openError == EXDEV {
                        newMounts.append(MountPoint(parent: tree.nodes[Int(id)].parent, name: tree.nodes[Int(id)].name))
                    }
                    killRoots.append(id)
                } else {
                    // Unreadable (permissions): keep it as a full scan does, empty and counted in openErrors.
                    tree.nodes[Int(id)].ownAlloc = 0
                    tree.nodes[Int(id)].ownLogical = 0
                    tree.nodes[Int(id)].ownFiles = 0
                    tree.nodes[Int(id)].ownCloneAware = 0
                    tree.nodes[Int(id)].unreadable = true
                    tree.nodes[Int(id)].incomplete = false
                    tree.stats.openErrors += 1
                    changed.append(id)
                    unreadable.append(id)
                }
                continue
            }
            // The folder's own clusters (`fstat` of the read, which the device check makes anyway) count in the folder.
            tree.nodes[Int(id)].ownAlloc = out.alloc + out.selfAlloc
            tree.nodes[Int(id)].ownLogical = out.logical
            tree.nodes[Int(id)].ownFiles = out.files
            tree.nodes[Int(id)].ownCloneAware = out.cloneAware + out.selfAlloc
            tree.nodes[Int(id)].unreadable = false
            tree.nodes[Int(id)].incomplete = out.incomplete
            changed.append(id)
            // Children are matched by their bytes: display forms of names that are not UTF-8 can collide.
            let rawAt = Dictionary(out.rawChildDirs.map { ($0.index, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            let listed = out.childDirs.indices.map { ChildKey(name: out.childDirs[$0], raw: rawAt[$0]) }
            var known = Set<ChildKey>()
            let onDisk = Set(listed)
            let denied = Set(out.deniedChildDirs.map { listed[$0] })
            tree.forEachChild(of: id) { c in
                let n = tree.nodes[Int(c)]
                let key = ChildKey(name: n.name, raw: tree.rawNames.isEmpty ? nil : tree.rawNames[c])
                known.insert(key)
                if !onDisk.contains(key) {
                    // An incomplete listing proves nothing about what it did not list: the child keeps its last result
                    // if it is still there as a directory of this volume. A rename shows up only as an event on the
                    // parent, so a child that is gone must go now, or it would be counted next to its new name.
                    // One `lstat` per unlisted child, only on this error path.
                    if !out.incomplete || !stillDirectory(c, in: tree) { killRoots.append(c) }
                    return
                }
                // A permission change shows up only as an event on the parent. A child we can no longer list is
                // emptied like a full scan leaves it; one that became listable again is walked.
                // A child re-read or rescanned on its own is settled there.
                if shallow.contains(c) || full.contains(c) { return }
                let denied = denied.contains(key)
                if denied && !n.unreadable {
                    tree.nodes[Int(c)].ownAlloc = 0
                    tree.nodes[Int(c)].ownLogical = 0
                    tree.nodes[Int(c)].ownFiles = 0
                    tree.nodes[Int(c)].ownCloneAware = 0
                    tree.nodes[Int(c)].unreadable = true
                    tree.nodes[Int(c)].incomplete = false
                    changed.append(c)
                    unreadable.append(c)
                } else if !denied && n.unreadable {
                    readable.append(c)
                }
            }
            for (k, name) in out.childDirs.enumerated() where !known.contains(listed[k]) {
                newDirs.append(Int32(tree.nodes.count))
                if let r = rawAt[k] { tree.rawNames[Int32(tree.nodes.count)] = r }
                tree.nodes.append(DirNode(parent: id, name: name))
            }
            for name in out.mountPoints { newMounts.append(MountPoint(parent: id, name: name)) }
            for l in out.deferredLinks { pendingLinks.append((id, l.inode, l.alloc, l.logical, l.cloneAware)) }
            if !out.cloneMembers.isEmpty { pendingClones.append((id, out.cloneMembers)) }
        }
        t.lap("diff")

        // 3. Mark removed directories and the old contents of fully rescanned ones, walking only those subtrees.
        tree.syncLinks()
        var affected = [Bool](repeating: false, count: tree.nodes.count)
        for id in shallow { affected[Int(id)] = true }
        for id in full { affected[Int(id)] = true }
        for id in unreadable { affected[Int(id)] = true }
        var stack: [Int32] = []
        func kill(_ root: Int32) {
            stack.append(root)
            while let i = stack.popLast() {
                guard !tree.nodes[Int(i)].isDead else { continue }
                tree.forEachChild(of: i) { stack.append($0) }
                tree.nodes[Int(i)].parent = DirNode.dead
                affected[Int(i)] = true
                report.dirsRemoved += 1
            }
        }
        for id in killRoots where !tree.nodes[Int(id)].isDead {
            changed.append(tree.nodes[Int(id)].parent)
            kill(id)
        }
        for id in full.sorted() + unreadable {
            changed.append(id)
            var kids: [Int32] = []
            tree.forEachChild(of: id) { kids.append($0) }
            kids.forEach(kill)
        }
        t.lap("dead")
        // Every record of a re-read, rescanned or removed directory is dropped; the re-read puts back what is still there.
        tree.hardlinks.forget { Int($0) < affected.count && affected[Int($0)] }
        tree.clones.forget { Int($0) < affected.count && affected[Int($0)] }
        // Likewise the mount points listed by those directories; the re-reads and rescans record the current ones.
        tree.mountPoints.removeAll { Int($0.parent) < affected.count && affected[Int($0.parent)] }
        tree.mountPoints += newMounts
        t.lap("forget")

        for l in pendingLinks
        where !tree.nodes[Int(l.dir)].isDead
            && tree.hardlinks.claim(l.inode, by: l.dir, alloc: l.alloc, logical: l.logical, cloneAware: l.cloneAware)
        {
            tree.nodes[Int(l.dir)].ownAlloc += l.alloc
            tree.nodes[Int(l.dir)].ownLogical += l.logical
            tree.nodes[Int(l.dir)].ownCloneAware += l.cloneAware
            tree.nodes[Int(l.dir)].ownFiles += 1
        }
        for c in pendingClones where !tree.nodes[Int(c.dir)].isDead {
            tree.nodes[Int(c.dir)].ownCloneAware += tree.clones.claim(c.members, by: c.dir).bytes
        }

        // 4. Walk new directories and flagged subtrees in one parallel pass.
        // A flagged directory may have been removed by its parent's re-read (deleted, or now a mount point); a dead
        // node has no path of its own.
        let targets = (full.sorted() + newDirs + readable).filter { !tree.nodes[Int($0)].isDead }
        report.subtreesScanned = targets.count
        let gone = Scanner.rescanSubtrees(targets, in: tree, options: options, checkRootDevice: true)
        if let e = gone[0] { return .rootUnreadable(errno: e) }
        for (id, e) in gone where e == EXDEV || tree.rawNames[id] == nil {
            if e == EXDEV {
                tree.mountPoints.append(MountPoint(parent: tree.nodes[Int(id)].parent, name: tree.nodes[Int(id)].name))
            }
            changed.append(tree.nodes[Int(id)].parent)
            tree.nodes[Int(id)].parent = DirNode.dead
            report.dirsRemoved += 1
        }
        t.lap("rescan(\(targets.count))")
        if options.strictHardlinks && tree.hardlinks.unattributed { return unattributed() }

        // 5. A file changed through a link in a directory that does not own it: if only that directory got an
        // event, the owner was not re-read and still counts the old size.
        for (dir, d) in tree.hardlinks.takeDrift() where !tree.nodes[Int(dir)].isDead {
            tree.nodes[Int(dir)].ownAlloc += d.alloc
            tree.nodes[Int(dir)].ownLogical += d.logical
            tree.nodes[Int(dir)].ownCloneAware += d.cloneAware
            changed.append(dir)
        }

        // 6. An inode whose owner lost its link while another directory still has one moves to that directory;
        // likewise a clone family whose owner lost its member.
        for m in tree.hardlinks.resolveOrphans() {
            tree.nodes[Int(m.dir)].ownAlloc += m.alloc
            tree.nodes[Int(m.dir)].ownLogical += m.logical
            tree.nodes[Int(m.dir)].ownCloneAware += m.cloneAware
            tree.nodes[Int(m.dir)].ownFiles += 1
            changed.append(m.dir)
        }
        for m in tree.clones.resolveOrphans() {
            tree.nodes[Int(m.dir)].ownCloneAware += m.alloc
            changed.append(m.dir)
        }
        // 7. A family that is new to the tree although its original was already there: the original was cloned
        // after the snapshot and its directory, not re-read, still counts it as a plain file. That directory
        // becomes the owner; the member's directory stops counting it. Costs two syscalls per such family.
        tree.syncLinks()
        let adopted = adoptOriginals(
            tree.clones.takeCreated(), in: tree, prefixes: prefixes,
            settled: { Int($0) < firstNew && !affected[Int($0)] })
        changed += adopted
        changed += Scanner.applyPreferredOriginals(tree)
        t.lap("links+orphans(\(adopted.count) clone originals adopted)")

        // A record whose directory was removed after it was made (its parent re-read as gone), or made twice.
        var seen = Set<MountPoint>()
        tree.mountPoints.removeAll { tree.nodes[Int($0.parent)].isDead || !seen.insert($0).inserted }

        tree.updateTotals(changed: changed, firstNew: firstNew)
        t.lap("totals")
        return nil
    }

    struct MountChanges {
        /// Live directories of the tree on which another volume is mounted now.
        var mounted: [Int32] = []
        /// Directories listing a recorded mount point that is no longer one.
        var uncovered: [Int32] = []
    }

    /// Compares the mount table with the tree. `mounted`: live directories of the tree on which another volume is
    /// mounted now; a full scan never has a node for a mount point, so each one was mounted after the snapshot.
    /// `uncovered`: parents of recorded mount points (`DiskTree.mountPoints`) that are no longer in the mount table.
    /// One `getfsstat` per update; the child links are synced and `lstat` called only for mount points inside the root,
    /// the tree lookup first (no `lstat` of an unrelated, perhaps slow, network volume). A volume on our own device
    /// (the data volume of the boot volume group) is part of the tree. If the table cannot be read, every recorded
    /// mount point's parent is re-read: a few directory listings, never a stale folder.
    /// The mount table names a mount point by its firmlink path (`/private/tmp/t/mnt`); for a root given by its
    /// data-volume path (`/System/Volumes/Data/private/tmp/t`, or the data volume itself) such a name is rewritten to
    /// the data-volume form before it is matched. A recorded mount point not found in the table is checked with one
    /// `lstat` before it is called gone: the table keeps the old name after a parent is renamed.
    static func mountChanges(
        _ tree: DiskTree, prefixes: [String], aliases: [FirmlinkTable.Alias],
        firmlinks: FirmlinkTable
    ) -> MountChanges {
        var out = MountChanges()
        let onDataVolume =
            !firmlinks.dataRoot.isEmpty
            && FirmlinkTable.isInside(tree.rootPath, firmlinks.dataRoot, orEqual: true)
        let recordedParents = { Array(Set(tree.mountPoints.map(\.parent))) }
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else {
            out.uncovered = recordedParents()
            return out
        }
        // Room for a few mounts made between the two calls. Plain C structs: the kernel fills the first `got`.
        let capacity = Int(count) + 8
        let mounts = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { mounts.deallocate() }
        let got = getfsstat(mounts, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard got > 0 else {
            out.uncovered = recordedParents()
            return out
        }
        var synced = false
        var current = Set<MountPoint>()
        for i in 0..<Int(got) {
            let path = withUnsafeBytes(of: mounts[i].f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            var comps = relativeComponents(path, prefixes: prefixes, aliases: aliases)
            if comps == nil && onDataVolume, let dataPath = firmlinks.dataVolumePath(path) {
                comps = relativeComponents(dataPath, prefixes: prefixes, aliases: aliases)
            }
            guard let comps, let last = comps.last else { continue }
            if !synced {
                tree.syncLinks()
                synced = true
            }
            var parent: Int32 = 0
            var found = true
            for c in comps.dropLast() {
                guard let child = tree.child(of: parent, named: String(c)) else {
                    found = false
                    break
                }
                parent = child
            }
            guard found else { continue }
            let name = String(last)
            current.insert(MountPoint(parent: parent, name: name))
            guard let id = tree.child(of: parent, named: name) else { continue }
            var st = stat()
            if lstat(path, &st) == 0 && st.st_dev == tree.rootDev { continue }
            out.mounted.append(id)
        }
        var parents = Set<Int32>()
        for m in tree.mountPoints where !current.contains(m) && !tree.nodes[Int(m.parent)].isDead {
            // Still another volume's root under the tree's name for it: not gone.
            let base = tree.path(of: Int(m.parent))
            var st = stat()
            if lstat((base == "/" ? "" : base) + "/" + m.name, &st) == 0 && st.st_dev != tree.rootDev { continue }
            if parents.insert(m.parent).inserted { out.uncovered.append(m.parent) }
        }
        return out
    }

    /// `c` is still a directory on the tree's volume at its path (one `lstat`, by bytes when it has a raw name).
    private static func stillDirectory(_ c: Int32, in tree: DiskTree) -> Bool {
        var st = stat()
        let found = tree.cPath(of: Int(c)).map { lstat($0, &st) } ?? lstat(tree.path(of: Int(c)), &st)
        return found == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_dev == tree.rootDev
    }

    /// Reads each directory once with up to `options.threads` workers; results are in input order.
    /// Invariant: nothing mutates the hard-link table while this runs. Workers only call `vet`, which reads the
    /// table under its lock; every claim is deferred (the closure returns nil) and made after `forget`, on one thread.
    /// `cPaths[k]`, when set, is what is opened for `paths[k]` (`DiskTree.cPath(of:)`).
    private static func readDirectories(
        _ paths: [String], cPaths: [[CChar]?], tree: DiskTree,
        options: ScanOptions
    ) -> [DirOutcome] {
        guard !paths.isEmpty else { return [] }
        let config = DirReader.Config(
            rootDev: tree.rootDev, options: options, userAccess: true,
            exclusions: tree.exclusions, checkOwnDevice: true, allocUnit: Scanner.allocationUnit(of: tree.rootPath))
        let hardlinks = tree.hardlinks
        var results = [DirOutcome](repeating: DirOutcome(), count: paths.count)
        let nextIndex = Atomic<Int>(0)
        let workers = min(options.threads, paths.count)
        results.withUnsafeMutableBufferPointer { buf in
            // Each index is written by exactly one worker; `concurrentPerform` returns after all of them finish.
            nonisolated(unsafe) let out = buf
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                let reader = DirReader(config)
                defer { reader.deallocate() }
                while true {
                    let k = nextIndex.wrappingAdd(1, ordering: .relaxed).oldValue
                    guard k < paths.count else { break }
                    let dirPath = paths[k]
                    var t0 = Timings.enabled ? Timings.Lap("apply") : nil
                    out[k] = reader.read(dirPath, cPath: cPaths[k]) { inode, alloc, _, _, name in
                        hardlinks.vet(inode, alloc: alloc, dirPath: dirPath, name: name)
                        return nil
                    }
                    if let mark = t0?.mark, ContinuousClock.now - mark > .milliseconds(20) {
                        t0?.lap("  slow read: \(out[k].files) files, \(dirPath)")
                    }
                }
            }
        }
        return results
    }

    /// For each family in `created` whose original file was not seen by this update: if the original is a single-link
    /// full clone of the family in a listed (not unreadable) directory that `settled` says was not re-read, that directory
    /// becomes the owner (it counts the file already) and the previous owner stops counting it.
    private static func adoptOriginals(
        _ created: [UInt64], in tree: DiskTree, prefixes: [String],
        settled: (Int32) -> Bool
    ) -> [Int32] {
        guard !created.isEmpty else { return [] }
        var fs = statfs()
        guard statfs(tree.rootPath, &fs) == 0 else { return [] }
        var fsid = fs.f_fsid
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var changed: [Int32] = []
        for cid in Set(created) {
            guard let e = tree.clones.entry(cid), e.original < 0, e.owner >= 0 else { continue }
            guard fsgetpath(&buf, buf.count, &fsid, cid) > 0 else { continue }
            let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard isSingleLinkClone(path, cloneID: cid),
                let comps = relativeComponents(path, prefixes: prefixes, aliases: tree.aliases), !comps.isEmpty
            else { continue }
            var dir: Int32 = 0
            var found = true
            for c in comps.dropLast() {
                guard let child = tree.child(of: dir, named: String(c)) else { found = false; break }
                dir = child
            }
            guard found, !tree.nodes[Int(dir)].isDead, !tree.nodes[Int(dir)].unreadable, settled(dir),
                let moved = tree.clones.adopt(cid, by: dir)
            else { continue }
            tree.nodes[Int(moved.previous)].ownCloneAware -= moved.alloc
            changed.append(moved.previous)
        }
        return changed
    }

    /// `path` is a regular file with one link, the original of clone family `cloneID`, sharing all its blocks.
    private static func isSingleLinkClone(_ path: String, cloneID: UInt64) -> Bool {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        var buf = [UInt8](repeating: 0, count: 128)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard
                getattrlist(
                    path, &al, raw.baseAddress, raw.count,
                    UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0
            else { return false }
            var f = UnsafeRawPointer(raw.baseAddress!) + 4
            let returned = f.loadUnaligned(as: attribute_set_t.self)
            f += MemoryLayout<attribute_set_t>.size
            let want = attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
            let wantFork = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
            guard returned.commonattr & want == want, returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0,
                returned.forkattr & wantFork == wantFork
            else { return false }
            let type = f.loadUnaligned(as: UInt32.self)
            let fileID = (f + 4).loadUnaligned(as: UInt64.self)
            let links = (f + 12).loadUnaligned(as: UInt32.self)
            let cid = (f + 16).loadUnaligned(as: UInt64.self)
            let ext = (f + 24).loadUnaligned(as: UInt64.self)
            return type == UInt32(VREG.rawValue) && links == 1 && fileID == cloneID && cid == cloneID
                && ext & UInt64(EF_SHARES_ALL_BLOCKS) != 0
        }
        return ok
    }

    /// FSEvents may report a path through the Data volume's firmlink rather than the path we scanned, and the mount
    /// table names mount points that way: a root given by its data-volume path
    /// (`/System/Volumes/Data/private/tmp/t`) is also matched under its firmlink spelling (`/private/tmp/t`).
    static func rootPrefixes(_ root: String, firmlinks: FirmlinkTable = .system) -> [String] {
        var out = [root]
        if let real = realpath(root, nil) {
            out.append(String(cString: real))
            free(real)
        }
        // Never inside the tree: a firmlink source lies on the system volume, outside /System/Volumes/Data.
        if let linked = firmlinks.firmlinkPath(root) { out.append(linked) }
        // Only a twin outside the tree: for "/" or "/System" this path is a real directory of the tree itself
        // (events there must keep their own path), not another view of the root.
        let twin = "/System/Volumes/Data" + (root == "/" ? "" : root)
        if !FirmlinkTable.isInside(twin, root, orEqual: true) { out.append(twin) }
        return Array(Set(out.map { $0 == "/" ? "" : $0 }))
    }

    /// Components of `path` below the tree's root, or nil when it is outside. A data-volume path the tree reaches
    /// through a firmlink is first rewritten to the firmlink path.
    static func relativeComponents(
        _ path: String, prefixes: [String],
        aliases: [FirmlinkTable.Alias] = []
    ) -> [Substring]? {
        var p = Substring(path)
        while p.count > 1 && p.hasSuffix("/") { p = p.dropLast() }
        if !aliases.isEmpty { p = aliases.translate(p) }
        for prefix in prefixes {
            if p == prefix || (prefix.isEmpty && p == "/") { return [] }
            if p.hasPrefix(prefix + "/") {
                return p.dropFirst(prefix.count + 1).split(separator: "/")
            }
        }
        return nil
    }
}

// MARK: - FSEvents history replay

final class EventHistory: @unchecked Sendable {
    struct Event {
        let path: String
        let mustScanSubDirs: Bool
    }

    private enum Phase { case history, live, finished }

    var events: [Event] = []
    /// Set when FSEvents reports lost history: the flag names and the event path.
    var untrusted: (flags: [String], path: String)?
    /// Id of the barrier event: every change made before `fetch` was called has an id at or below it.
    private(set) var barrierId: FSEventStreamEventId = 0
    private var phase = Phase.history
    private var barrierPaths: Set<String> = []
    private let historyDone = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)

    /// Replays every directory-level event under `root` since `since`, up to a barrier event made by this call.
    ///
    /// HistoryDone alone is not enough: fseventsd assigns event ids when it reads the kernel queue, so a change
    /// finished just before this call may still be unnumbered (its id will be above `FSEventsGetCurrentEventId()`)
    /// and is delivered as a live event after HistoryDone. `FSEventStreamFlushSync` does not wait for it either.
    /// So after HistoryDone we create a file in a private directory that the same stream watches: the kernel
    /// queues that event after every earlier change, and the stream delivers in id order, so once it arrives
    /// every earlier change under `root` has been delivered.
    static func fetch(root: String, since: FSEventStreamEventId) -> Result<EventHistory, UpdateFailure> {
        fetch(root: root, since: since, into: EventHistory())
    }

    #if DEBUG
        static func fetch(root: String, since: FSEventStreamEventId, faults: HistoryFaults) -> Result<
            EventHistory, UpdateFailure
        > {
            let history = EventHistory()
            history.faults = faults
            return fetch(root: root, since: since, into: history)
        }

        var faults = HistoryFaults()
    #endif

    private static func fetch(root: String, since: FSEventStreamEventId, into history: EventHistory) -> Result<
        EventHistory, UpdateFailure
    > {
        guard let barrierDir = makeBarrierDir() else {
            return .failure(.streamFailed("barrier directory: \(String(cString: strerror(errno)))"))
        }
        let marker = barrierDir + "/barrier"
        defer {
            unlink(marker)
            rmdir(barrierDir)
        }
        history.barrierPaths = Set(Incremental.rootPrefixes(barrierDir))
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(history).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let h = Unmanaged<EventHistory>.fromOpaque(info!).takeUnretainedValue()
            guard h.phase != .finished else { return }
            let paths = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count {
                #if DEBUG
                    let f = flags[i] | h.faults.extraFlags
                #else
                    let f = flags[i]
                #endif
                let path = paths[i] as! String
                if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                    #if DEBUG
                        if h.faults.dropHistoryDone { continue }
                    #endif
                    if h.phase == .history {
                        h.phase = .live
                        h.historyDone.signal()
                    }
                    continue
                }
                let lost = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                        | kFSEventStreamEventFlagRootChanged)
                // Untrusted history means a full scan anyway, so there is no barrier to wait for.
                let untrusted = f & lost != 0
                #if DEBUG
                    let isBarrier = h.phase == .live && h.isBarrier(path) && !h.faults.dropBarrier
                #else
                    let isBarrier = h.phase == .live && h.isBarrier(path)
                #endif
                if untrusted || isBarrier {
                    if untrusted { h.untrusted = (EventHistory.lostFlagNames(f), path) } else { h.barrierId = ids[i] }
                    if h.phase == .history { h.historyDone.signal() }
                    h.phase = .finished
                    h.done.signal()
                    return
                }
                let must = f & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                h.events.append(Event(path: path, mustScanSubDirs: must))
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context,
                [root, barrierDir] as CFArray, since, 0, flags)
        else {
            return .failure(.streamFailed("FSEventStreamCreate"))
        }
        let queue = DispatchQueue(label: "Fil.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return .failure(.streamFailed("FSEventStreamStart"))
        }
        // 30 s for the history replay; the barrier event, made after it, gets its own short timeout.
        #if DEBUG
            let historyLimit = history.faults.historyLimit ?? 30, barrierLimit = history.faults.barrierLimit ?? 2
        #else
            let historyLimit = 30, barrierLimit = 2
        #endif
        var failure: UpdateFailure?
        if history.historyDone.wait(timeout: .now() + .seconds(historyLimit)) != .success {
            failure = .historyTimeout(seconds: historyLimit)
        } else {
            let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                if history.done.wait(timeout: .now() + .seconds(barrierLimit)) != .success {
                    failure = .barrierTimeout(seconds: barrierLimit)
                }
            } else {
                failure = .streamFailed("barrier file: \(String(cString: strerror(errno)))")
            }
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        queue.sync {}  // the callback runs on `queue`; drain it before reading `events`
        if let lost = history.untrusted { return .failure(.historyUntrusted(flags: lost.flags, path: lost.path)) }
        if let failure { return .failure(failure) }
        return .success(history)
    }

    private static func lostFlagNames(_ f: FSEventStreamEventFlags) -> [String] {
        let names: [(Int, String)] = [
            (kFSEventStreamEventFlagUserDropped, "UserDropped"),
            (kFSEventStreamEventFlagKernelDropped, "KernelDropped"),
            (kFSEventStreamEventFlagEventIdsWrapped, "EventIdsWrapped"),
            (kFSEventStreamEventFlagRootChanged, "RootChanged"),
        ]
        return names.filter { f & FSEventStreamEventFlags($0.0) != 0 }.map(\.1)
    }

    private func isBarrier(_ path: String) -> Bool {
        var p = Substring(path)
        while p.count > 1 && p.hasSuffix("/") { p = p.dropLast() }
        return barrierPaths.contains(String(p))
    }

    /// A fresh directory of our own, resolved through symlinks (/var -> /private/var) as FSEvents reports it.
    private static func makeBarrierDir() -> String? {
        var template = Array((NSTemporaryDirectory() + "Fil-fsevents.XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { return nil }
        guard let real = realpath(made, nil) else {
            rmdir(made)
            return nil
        }
        defer { free(real) }
        return String(cString: real)
    }
}

/// A child directory as the update diff matches it: by the bytes of its name, never by `String` equality, which treats
/// canonically equivalent names (NFC and NFD `é`) as one; both can exist side by side on some volumes (SMB, NFS).
/// A valid name keeps its `String` (no copy); a name that is not UTF-8 is its raw bytes.
private struct ChildKey: Hashable {
    let name: String
    let raw: [UInt8]?

    static func == (a: ChildKey, b: ChildKey) -> Bool {
        switch (a.raw, b.raw) {
        case let (x?, y?): x == y
        case let (x?, nil): x.elementsEqual(b.name.utf8)
        case let (nil, y?): a.name.utf8.elementsEqual(y)
        case (nil, nil): a.name.utf8.elementsEqual(b.name.utf8)
        }
    }

    func hash(into h: inout Hasher) {
        if let raw {
            raw.withUnsafeBytes { h.combine(bytes: $0) }
        } else if name.utf8.withContiguousStorageIfAvailable({ h.combine(bytes: UnsafeRawBufferPointer($0)) }) == nil {
            Array(name.utf8).withUnsafeBytes { h.combine(bytes: $0) }
        }
    }
}
