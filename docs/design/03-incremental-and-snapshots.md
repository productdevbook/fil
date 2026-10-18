# 03 — Incremental updates and snapshots

How a `DiskTree` is saved after a scan, loaded on the next run, and brought up to date by replaying FSEvents
instead of walking the disk again. Covers `Sources/ScanCore/Snapshot.swift`, `Sources/ScanCore/Incremental.swift`
and their callers in `Sources/fil/Scan.swift` (`scan`) and `Sources/fil/Cleanup.swift` (`list`, `clean`).
Byte accounting (`alloc`, `cloneaware`, `shared`, firmlinks, clone families) is defined in
`docs/specs/accounting.md`; this chapter only says how an update keeps it exact.

Status tags: **[Exists]** in the code today (file:line), **[Change]** in the code, changed by this chapter
(reason and issue), **[New]** not in the code.

## 1. The rule

- **[Exists]** An incremental update replays FSEvents since the snapshot's event id; when the history cannot be
  trusted the caller discards the tree and runs a full scan (`Incremental.swift:18-19, 58-59`;
  `Scan.swift:74-91`). After an `UpdateFailure` the tree may be partly updated in place and must not be shown or
  saved.
- **[Exists]** Never present sizes known to be stale or wrong as current. The CLI meets this by construction:
  nothing from a snapshot is printed before `Incremental.update` succeeds; on failure the full scan's result is
  printed instead (`Scan.swift:70-91`). A snapshot that fails validation is never used (section 6).
- **[Exists]** A clearly labelled last-known result is allowed; the CLI has no such output today (section 9).
- **[New]** Gaps where the rule is broken today: Mount/Unmount (section 4.6, #4), the device-crossing mode not
  stored (section 5.4, #5) and strict runs inheriting tolerant uncertainty (section 8.3).

## 2. End-to-end flow in `fil scan`

**[Exists]** `runScan` (`Scan.swift:58-97`):

| Step | Code | Notes |
|---|---|---|
| 1 | `--full` given? skip to step 4 | `Scan.swift:70` |
| 2 | `Snapshot.load(rootPath: path, privateSize:)` | `nil` → step 4, silently (section 6) |
| 3 | `Incremental.update(cached, options:)` | success → `tree = cached`; failure → `mode` records the reason |
| 4 | `tree ?? Scanner.scan(path, ...)` | full scan; its errors are thrown |
| 5 | `if !(unchanged && Snapshot.advance(scanned)) { try Snapshot.save(scanned) }` | `unchanged` = success with `report.events == 0` |
| 6 | print | header summary is one of three strings (table below) |

`path` is the argument after `standardizingPath` (default `NSHomeDirectory()`); it is the snapshot key.

| Outcome | Summary text at the end of line 2 (`Scan.swift:79-80, 61`) | `--porcelain` `mode=` |
|---|---|---|
| update, 0 events | `up to date from snapshot` | `incremental` |
| update, N events | `updated from snapshot, N change(s)` (N = raw event count, not files) | `incremental` |
| no snapshot / rejected / failed / `--full` | `full scan` | `full` |

- **[Exists]** `-v` adds `timing   <ms> [<mode>]`; `mode` is
  `incremental: load X ms, N events in Y ms, apply Z ms (D dirs re-read, S subtrees walked, R removed)` or
  `full scan (incremental not usable: <UpdateFailure.description>)` (`Scan.swift:81-85, 136`).
- **[Exists]** `list` and `clean` run the same steps on the home folder (or `--home DIR`) with
  `ScanOptions(strictHardlinks: false)` (tolerant mode); the failure reason appears only with the hidden
  `--timings` flag, on stderr: `incremental update <ms>  (not usable: <why>; full scan)` (`Cleanup.swift:37-61`).
- **[Exists]** `scan` defaults to strict hard links; `--tolerant-hardlinks` switches to tolerant
  (`Scan.swift:31`).

## 3. `Incremental.update`

**[Exists]** `Incremental.update(_:options:) -> Result<UpdateReport, UpdateFailure>` (`Incremental.swift:60-98`),
in order:

1. `Scanner.preventCloudDownloads()` (no `SF_DATALESS` materialisation).
2. `lstat(tree.rootPath)`; failure → `rootUnreadable(errno:)`.
3. `Scanner.volumeUUID(st.st_dev)` (`FSEventsCopyUUIDForDevice`). If `tree.volumeUUID` is empty or differs →
   `volumeChanged(expected:found:)`. FSEvents ids are per volume, so an id from another volume means nothing.
4. `tree.rootDev = st.st_dev` (device numbers change across reboots; the stored one is only a hint).
5. `options.firmlinks.aliases(for: tree.rootPath) == tree.aliases`, else `firmlinksChanged`.
6. `startWallClock = Scanner.nowNanoseconds()` (CLOCK_REALTIME, ns), taken before the barrier is made.
7. `EventHistory.fetch(root:since: tree.eventId)` (section 4).
8. `applyTracked(events, ...)` (section 5); a returned failure is passed through.
9. `tree.eventId = history.barrierId`, `tree.scanStart = startWallClock`.
10. Tolerant mode only: if the hard-link registry met unattributed links, `report.uncertainBytes` /
    `uncertainPaths` are filled and `tree.uncertainBytes += report.uncertainBytes`.

`UpdateReport` fields (`Incremental.swift:6-16`):

| Field | Meaning |
|---|---|
| `events` | events delivered before the barrier, including ones outside the root |
| `dirsRead` | directories re-read shallowly |
| `subtreesScanned` | directories walked in full (flagged, new, or readable again) |
| `dirsRemoved` | nodes marked dead |
| `historyTime`, `applyTime` | `Duration` |
| `uncertainBytes`, `uncertainPaths` | tolerant mode, section 7.3 |

## 4. FSEvents replay (`EventHistory`)

### 4.1 Stream

**[Exists]** `EventHistory.fetch` (`Incremental.swift:474-553`):

| Parameter | Value |
|---|---|
| paths | `[root, barrierDir]` |
| `sinceWhen` | `tree.eventId` (taken with `FSEventsGetCurrentEventId()` before a full scan starts, `Scanner.swift:34`, or the previous barrier id) |
| latency | `0` |
| create flags | `UseCFTypes \| NoDefer \| WatchRoot` (no `FileEvents`: every event path is a directory) |
| queue | serial `DispatchQueue(label: "Fil.fsevents")` |

### 4.2 Phases and timeouts

**[Exists]** `Phase { history, live, finished }`:

| Phase | Entered when | Events are |
|---|---|---|
| `history` | stream start | appended to `events` |
| `live` | an event with `HistoryDone`; `historyDone` semaphore signalled | appended to `events`, unless it is the barrier |
| `finished` | barrier event in `live`, or any lost-history flag in any phase | ignored (callback returns at once) |

After `HistoryDone`, fseventsd may still hold changes that finished before `fetch` was called but have not been
numbered yet; they arrive as live events, and `FSEventStreamFlushSync` does not wait for them. So the barrier:

1. `barrierDir` = `realpath(mkdtemp(NSTemporaryDirectory() + "Fil-fsevents.XXXXXX"))` (`makeBarrierDir`,
   `Incremental.swift:570-579`); the path is resolved because FSEvents reports `/private/var/...`.
2. Wait up to **30 s** (`historyLimit`) for `historyDone`. Timeout → `historyTimeout(seconds: 30)`.
3. Create `barrierDir + "/barrier"` with `open(O_WRONLY | O_CREAT | O_EXCL, 0o600)`; failure →
   `streamFailed("barrier file: <strerror>")`.
4. Wait up to **2 s** (`barrierLimit`) for `done`. Timeout → `barrierTimeout(seconds: 2)`.
5. The barrier event is a live event whose path (trailing `/` stripped) is in `rootPrefixes(barrierDir)`. The kernel
   queues it after every earlier change and the stream delivers in id order, so when it arrives every earlier change
   under `root` has been delivered. Its id becomes `barrierId`, the tree's next `eventId`.
6. Stop, invalidate and release the stream; `queue.sync {}` drains the callback before `events` is read.
7. `defer`: `unlink(marker)`, `rmdir(barrierDir)`.

Precedence of results: `historyUntrusted` beats any timeout; otherwise the timeout or `streamFailed`; otherwise
success. An untrusted flag in the `history` phase also signals `historyDone`, so `fetch` does not wait 30 s for a
replay that is already worthless.

### 4.3 Lost-history flags

**[Exists]** `UserDropped | KernelDropped | EventIdsWrapped | RootChanged` (`Incremental.swift:501-503`) →
`historyUntrusted(flags: <names>, path: <event path>)`. `RootChanged` comes from `WatchRoot`: the root (or a
parent) was moved or deleted.

### 4.4 Events kept

**[Exists]** Every other event is kept as `Event(path:, mustScanSubDirs: flags & MustScanSubDirs != 0)`. No other
flag is looked at.

### 4.5 Setup failures

**[Exists]** `streamFailed` reasons: `"barrier directory: <strerror>"`, `"FSEventStreamCreate"`,
`"FSEventStreamStart"`, `"barrier file: <strerror>"`.

### 4.6 Mount and Unmount

- **[Exists]** `Mount` / `Unmount` events are ordinary events. The mount point is re-read, and `DirReader.read`
  never checks the device of the directory it opens (only of its children, `Scanner.swift:366`). After
  `hdiutil attach -mountpoint ~/mnt image.dmg`, an update counts the image's files as `~/mnt`'s own files, and the
  result is presented as current.
- **[Change] (#4)** Check the device of every directory an update opens by path, instead of trusting the event
  flags:
  - `DirReader.Config` gains `checkOwnDevice: Bool` (default `false`). When set, `read` calls `fstat(fd)` after
    `open`; if `st_dev != rootDev && !options.crossDevices` it returns `opened = false`,
    `openError = EXDEV`, `stats.mountsSkipped = 1` (not `openErrors`).
  - `DirOutcome.isGone` also returns true for `EXDEV`, so the node is removed exactly as a full scan leaves a
    mount point out (the parent's `ATTR_CMN_DEVID` check skips it).
  - Set by `Incremental.readDirectories` for every read, and by `ParallelScan` for root items only
    (`item.id < rootIds.count`) when called from `Incremental.apply`. Children are already filtered by their
    parent's `DEVID`. Cost: one `fstat` per re-read directory and per rescanned subtree root, none per file, none
    in a full scan.
  - Unmount needs nothing more: the mount point is not in the tree, the event maps to its parent (section 5.1), the
    parent's re-read now lists it, and it is walked as a new directory.
  - Rejected: adding `Mount | Unmount` to the lost-history set. Simpler, but plugging in any disk under the root
    (`/Volumes/*` for `fil scan /`) would force a full scan of `/` (56 s measured) on the next run.
  - `rootUnreadable(errno: EXDEV)` cannot occur for the root: step 3 of section 3 fails first with
    `volumeChanged`.

## 5. Applying events (`Incremental.apply`)

**[Exists]** `applyTracked` (`Incremental.swift:101-112`) puts the registries in update mode
(`hardlinks.beginUpdate(cutoff: tree.scanStart, strict:)`, `trackDrift()`, `clones.beginUpdate()`) and always
leaves it (`endUpdate`, `takeDrift`, `takeCreated` in `defer`). Tests call it directly with chosen events. `apply`
(`Incremental.swift:116-317`) returns `nil` at once for an empty event list. Steps:

### 5.1 Map events to nodes

- **[Exists]** `prefixes = rootPrefixes(tree.rootPath)` (`Incremental.swift:416-427`): the root as given, its
  `realpath`, and its data-volume twin `"/System/Volumes/Data" + root` only when that twin is outside the tree
  (`FirmlinkTable.isInside(twin, root, orEqual: true)` is false). `"/"` is stored as `""`. For `/` and `/System` the
  twin is a real directory of the tree, and events there keep their own path.
- **[Exists]** `relativeComponents(path, prefixes:, aliases:)` (`Incremental.swift:431-443`): strip trailing `/`;
  rewrite through the aliases (section 7.5); return the components below the first matching prefix, `[]` for the
  root itself, `nil` (event ignored) when outside.
- **[Exists]** Walk the components from node 0 with `tree.child(of:named:)` and stop at the first unknown name.
  The deepest known node gets the event: into `full` if `mustScanSubDirs`, else into `shallow`.
- **[Exists]** Deduplicate: drop a `shallow` id when it or an ancestor is in `full`; drop a `full` id when an
  ancestor is in `full`.
- **[Change] (#17)** `child(of:named:)` (`DiskTree.swift:480-488`) walks the whole sibling list and allocates a
  `String` per component (`String(c)` at `Incremental.swift:134`). A directory with 100 k children and many events
  is O(events × siblings). Change:
  - `child(of:named:)` takes `some StringProtocol` (a `Substring` component) and compares with `==`, no allocation.
  - `ChildLinks` gains `index: [Int32: [String: Int32]]`, built for a parent the first time a lookup in it walks
    more than **32** siblings. `syncLinks` adds appended children to an existing index (last writer wins for a
    name). A hit is valid only if `nodes[hit].parent == id`; otherwise fall back to the linear walk and rebuild that
    parent's index. `compact` clears `index` with `first`/`next`.

### 5.2 Shallow re-read

**[Exists]** A shallow re-read lists one directory again (its files and the names of its child directories), not
its subtree.

- Directories in `shallow`, sorted by id, are read by `readDirectories` (`Incremental.swift:322-352`):
  `min(options.threads, count)` workers (`DispatchQueue.concurrentPerform`), one `DirReader` each,
  `Config(rootDev:, options:, userAccess: true, exclusions: tree.exclusions)`. `userAccess` reports child
  directories the user may not list (`R_OK | X_OK` missing), because a permission change is reported as an event
  on the parent only.
- Workers never mutate the hard-link table: the claim closure calls `hardlinks.vet(...)` and returns `nil`, so
  every multiply-linked file lands in `DirOutcome.deferredLinks`; clone members land in `cloneMembers`.
- Strict mode: `tree.hardlinks.unattributed` after the reads → `unattributedHardLink(paths:)`.

Result per re-read id (`Incremental.swift:166-223`):

| Outcome | Action |
|---|---|
| open failed, id 0 | return `rootUnreadable(errno: openError)` |
| open failed, `isGone` (`ENOENT`, `ENOTDIR`, `ELOOP`) | kill the node and its subtree |
| open failed, other errno (`EACCES`, `EPERM`, ...) | own sizes = 0, `unreadable = true`, `stats.openErrors += 1`, subtree killed (kept as an empty node, like a full scan) |
| opened | own `alloc`/`logical`/`files`/`cloneAware` replaced, `unreadable = false`, children diffed |

Child diff, by name (`Set<String>`):

| Child | Action |
|---|---|
| known, not on disk | killed (deleted, or renamed: section 5.4) |
| known, on disk, itself in `shallow` or `full` | left to its own handling |
| known, now denied, was readable | emptied, `unreadable = true`, subtree killed |
| known, now listable, was `unreadable` | walked in full (`readable`) |
| on disk, unknown | appended as `DirNode(parent: id, name:)`, walked in full (`newDirs`) |

### 5.3 Full (recursive) rescan

- **[Exists]** `full` ids are not re-read shallowly: all their children are killed and the id itself becomes a
  rescan target. Targets = `full.sorted() + (newDirs + readable)` that are still alive, walked in one
  `Scanner.rescanSubtrees` pass (`ParallelScan`, `options.threads` workers) that overwrites the targets' own sizes
  and appends their descendants (`Incremental.swift:271-279`; `Scanner.swift:61-85`).
- **[Exists]** Rescan workers claim hard links directly and also `vet` them; strict mode re-checks
  `unattributed` after the pass.
- **[Exists]** A target whose open is `isGone` is marked dead; target 0 gone → `rootUnreadable`.
- **[Exists]** Killing (`Incremental.swift:233-242`) sets `parent = DirNode.dead` (−2) on every node of the subtree,
  marks it `affected`, counts `dirsRemoved`. Dead nodes stay in `nodes` until `compact` (at save).
- **[Exists]** Totals: `tree.updateTotals(changed:, firstNew:)` recomputes only nodes appended since the update
  began and the ancestor chains of `changed` (`DiskTree.swift:359-401`).

### 5.4 Renames

**[Exists]** There is no rename tracking; a rename is a delete plus a create, decided by names in the parent's
re-read:

- Directory renamed inside the root: the parent (and the destination parent, if different) get events → shallow
  re-read → the old name is killed, the new name is new and walked in full. An event on the old path maps to the
  old node, whose re-read is `isGone`. Cost: a full walk of the renamed subtree.
- Moved out of the root: killed. Moved in: walked as new.
- File renamed or moved: both parents re-read; sizes follow from their own listings.
- Case-only rename (`a` → `A`): names differ, so kill + walk.
- Unicode-normalisation-only rename (NFC ↔ NFD): Swift `String ==` treats the forms as equal, so the node keeps the
  old spelling. Harmless: APFS looks names up normalisation-insensitively, so `path(of:)` still opens it.
- **[Change] (#20)** Tests for case-only and non-ASCII renames are missing (section 11).

### 5.5 Forget, re-claim, drift, orphans

- **[Exists]** `affected` = every re-read, rescanned, unreadable-made or killed id. `hardlinks.forget` and
  `clones.forget` drop every record those directories hold; an owner that is dropped leaves its entry ownerless
  (`owner = -1`) while other links remain (`DiskTree.swift:211-230`, `Clones.swift:108-129`).
- **[Exists]** Then the deferred links are claimed in id order, one thread: a directory that becomes the owner adds
  `alloc`, `logical`, `cloneAware` and 1 file. Then deferred clone members are claimed; the owner adds the family's
  bytes to `ownCloneAware` (`Incremental.swift:259-268`). Claims happen only after `forget`, so a link still in the
  same directory is re-claimed rather than treated as a duplicate.
- **[Exists]** Drift (`Incremental.swift:284-289`): a link seen with sizes different from its record, in a
  directory that does not own it, means the file changed while only that directory got an event. The owner's own
  sizes are moved by the difference.
- **[Exists]** Orphans: `hardlinks.resolveOrphans()` gives each ownerless inode to the first other directory that
  still links it (+sizes, +1 file); `clones.resolveOrphans()` gives each ownerless family to the original's
  directory if it still holds a member, else the first other one (+`alloc` to `ownCloneAware`).
- **[Change] (#16)** `forget` and `resolveOrphans` walk the whole table, and `affected` is a `[Bool]` of
  `nodes.count`: an update is O(tree), not O(changes) as `Incremental.swift:114-115` says. Change:
  - Both registries keep `byDir: [Int32: [UInt64]]` (keys where the directory is owner, original or in `others`),
    maintained in `claim`, `adopt`, `preferOriginals`, `forget`, `resolveOrphans`, `remap`. Stale keys are allowed
    and skipped on use.
  - `forget(dirs: Set<Int32>)` replaces `forget(where:)` and touches only `byDir[d]` for `d` in the set; ownerless
    keys go into `orphans: Set<UInt64>`, which `resolveOrphans` walks instead of the table.
  - `affected` becomes `Set<Int32>`.
  - Acceptance: on a tree of ≥ 1 M files, an update after touching one file takes < 50 ms in `apply`
    (`fil scan -v`), and the incremental result still equals `--full`.

### 5.6 Clone originals cloned after the snapshot

**[Exists]** `adoptOriginals` (`Incremental.swift:357-384`). A family first seen in this update through a
non-original member (`CloneRegistry.created`) whose original was already in the tree: the original's directory was
not re-read and counts it as a plain file, so the family would be counted twice. For each such clone id with
`original < 0` and `owner >= 0`:

1. `fsgetpath(fsid of the root, cloneID)` → path (the original's file id equals the clone id).
2. `isSingleLinkClone`: one `getattrlist` (`FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED`); requires `VREG`, link count
   1, file id == clone id, `ATTR_CMNEXT_CLONEID` == clone id and `EF_SHARES_ALL_BLOCKS`.
3. Walk the path to its directory; it must be alive, not `unreadable`, older than the update
   (`id < firstNew`) and not `affected`.
4. `clones.adopt(cid, by: dir)`: that directory becomes owner and original; the previous owner subtracts `alloc`
   from `ownCloneAware` and moves to `others`.

Then `Scanner.applyPreferredOriginals` moves any family whose original's directory is not the owner. Cost: two
syscalls per such family, updates only.

### 5.7 Hard links older than the tree

- **[Exists]** `HardlinkRegistry.vet` (`DiskTree.swift:186-206`): a multiply-linked file with no record whose
  birth time (`fstatat`, `st_birthtimespec`) is before `scanStart` must have been counted earlier as a single-link
  file in a directory we cannot identify (a new link was made to an old file). It is "unattributed".
- **[Exists]** Strict (`scan` default): the update fails with `unattributedHardLink(paths:)`; at most 20 paths are
  kept (`maxUnattributedPaths`).
- **[Exists]** Tolerant (`--tolerant-hardlinks`, `list`, `clean`): the file is counted where met, its `alloc` is
  added once per inode to `DiskTree.uncertainBytes` and `UpdateReport.uncertainBytes`.

## 6. Snapshot file

### 6.1 Location

**[Change] (F-033)** File name = FNV-1a 64 of the resolved root path (F-011), a NUL byte and the mode byte (format 6),
as lowercase hex, `.bin`. Reason: `--private` and normal scans of the same root today share one file and reject
each other's snapshot, so alternating them always runs a full scan. The text below describes today.

- **[Exists]** `Snapshot.url(for:in:)` (`Snapshot.swift:16-21`): file name = 64-bit FNV-1a of the root path's UTF-8
  bytes (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`), lowercase hex without leading zeros, + `.bin`.
- **[Exists]** Directory (`Snapshot.swift:24-30`): `$FIL_SNAPSHOT_DIR` if set and non-empty (tests), else
  `~/Library/Caches/com.vucod.Fil/snapshots/`, created on save.
- **[Exists]** One file per root string: `/Users/code` and a symlinked spelling of it have separate snapshots. On a
  hash collision the stored `rootPath` does not match, `load` returns `nil` and the full scan overwrites the file.
  `--private` and plain runs of the same root share one file and overwrite each other (the mode byte rejects the
  other one).
- **[Exists]** The same directory also holds the tool-path cache of `CleanCore` (`Tools.swift:229`).

### 6.2 Format version 5 (current)

**[Exists]** Little-endian throughout (`Writer`, `Snapshot.swift:196-236`). A string is `u32` byte length +
UTF-8 bytes, no terminator.

Header:

| Offset | Size | Type | Field | Notes |
|---|---|---|---|---|
| 0 | 4 | u32 | `magic` | `0x4D545A31`; on disk the bytes read `1ZTM` (the comment's `"MTZ1"` is the big-endian reading) |
| 4 | 4 | u32 | `version` | `5` |
| 8 | 1 | u8 | `privateSize` | `0` or `1` |
| 9 | 4 | i32 | `rootDev` | hint only, replaced on update |
| 13 | 8 | u64 | `eventId` | `eventIdOffset = 13`; rewritten by `advance` |
| 21 | 8 | i64 | `scanStart` | ns since 1970 (CLOCK_REALTIME); rewritten by `advance` |
| 29 | 8 | i64 | `uncertainBytes` | |
| 37 | 4+n | string | `volumeUUID` | `CFUUIDCreateString` form, may be empty |
| … | 4+n | string | `rootPath` | |
| … | 4 | u32 | alias count | |
| … | per alias | string, string | `dataPath`, `source` | sorted by `dataPath` |

Body, in order:

| Section | Count | Record layout (offset within record) |
|---|---|---|
| nodes | u32 | `parent` i32 @0 · `flags` u8 @4 (bit 0 = `unreadable`, others 0) · `ownAlloc` i64 @5 · `ownLogical` i64 @13 · `ownFiles` i64 @21 · `ownCloneAware` i64 @29 · name length u32 @37 · name @41. Fixed part 41 bytes. |
| hard links | u32 | `inode` u64 @0 · `owner` i32 @8 · `alloc` i64 @12 · `logical` i64 @20 · `cloneAware` i64 @28 · others count u32 @36 · `others` i32 × n @40. Fixed part 40 bytes. |
| clone families | u32 | `cloneID` u64 @0 · `owner` i32 @8 · `original` i32 @12 (−1 if unknown) · `alloc` i64 @16 · others count u32 @24 · `others` i32 × n @28. Fixed part 28 bytes. |

Per node, stored: the four own sizes, `parent`, `unreadable`, `name` (node 0's name is the root path). Not stored:
totals (recomputed by `computeTotals` on load), dead nodes (`compact` runs first, renumbering ids and remapping
both registries, `Snapshot.swift:62`), child links (rebuilt lazily), `ScanStats` (#15), `crossDevices` (#5),
`strictHardlinks`.

History of the version (`Snapshot.swift:8-13`): 3 added the flags byte; 4 added `uncertainBytes`; 5 added aliases,
`ownCloneAware`, per-link `cloneAware` and the clone-family table. Older versions are not read.

### 6.3 Writing

- **[Exists]** `save` (`Snapshot.swift:60-117`): compact, encode into one `malloc` buffer (initial capacity
  `1024 + nodes × 60 + links × 48 + families × 32`, doubling), `Data.write(options: .atomic)` (temp file + rename).
  A reader never sees a half-written file.
- **[Exists]** `advance` (`Snapshot.swift:39-58`): after an update with 0 events the tree is unchanged, so only
  `eventId` and `scanStart` move: read bytes 0..<13, require bytes 0..<9 to equal this tree's magic, version and
  mode byte, then one 16-byte `pwrite` at offset 13. `false` (missing file, other format) → full `save`. `rootDev`
  is not rewritten (harmless: it is replaced on update).
- **[Exists]** Two processes on one root (e.g. `fil scan ~` and `fil list`): each `save` is atomic, last writer
  wins. An `advance` landing on the other process's newer file writes an older or equal barrier id (nothing
  changed up to its own barrier), so the next update replays a little more; it never skips a change.

### 6.4 Load validation

**[Exists]** `Snapshot.load(rootPath:privateSize:in:)` (`Snapshot.swift:120-192`) maps the file and returns `nil`,
never a partial tree, when any of these holds:

| # | Rejected when | Line |
|---|---|---|
| 1 | file missing or unreadable | 122 |
| 2 | `magic != 0x4D545A31` | 125 |
| 3 | `version != 5` | 125 |
| 4 | mode byte `!= (privateSize ? 1 : 0)` | 126 |
| 5 | stored `rootPath != rootPath` asked for | 132 |
| 6 | alias count `> remaining / 8` | 134 |
| 7 | node count `> remaining / 41` | 139 |
| 8 | a node record is truncated (fixed part or name) | 253-268 |
| 9 | node 0's parent `!= -1`, or node i's parent not in `0..<i` (no dead nodes, parent before child) | 146 |
| 10 | a hard-link `owner` not in `0..<count`, others count `> count`, or an `others` id out of range | 160-162 |
| 11 | no nodes | 165 |
| 12 | family count `> remaining / 24` | 168 |
| 13 | a family `owner` not in `0..<count`, `original` not in `-1..<count`, others count `> remaining / 4`, or an `others` id out of range | 175-179 |
| 14 | any read past the end (`Reader.ok == false`) | throughout |

Not checked: trailing bytes after the family table; `volumeUUID`, `eventId`, `scanStart` (the update checks the
volume; FSEvents judges the id); invalid UTF-8 in names (decoded with U+FFFD, so the directory's path no longer
opens and a later re-read removes it); duplicate or `/`-containing names; an owner repeated in `others`.
`uncertainBytes < 0` is clamped to 0. The count bounds only cap allocations; the family bound uses 24 although a
record's fixed part is 28 bytes (still safe: every read is bounds-checked).

**[New]** A rejected snapshot and a missing one look the same to the user (`full scan`). `load` returns
`Result<DiskTree, Snapshot.LoadFailure>` with cases `missing`, `notSnapshot` (magic), `otherVersion(UInt32)`,
`otherMode`, `otherRoot`, `corrupt`; `scan -v` prints `snapshot not used: <case>` and `list`/`clean --timings`
add it to the `snapshot load` line. `nil`-returning behaviour is otherwise unchanged.

### 6.5 Changes to the format

- **[Change] (#5)** The device-crossing mode is not stored, so a tree scanned with `crossDevices` on and updated
  with it off (or the reverse) is presented as current but wrong. Byte 8 becomes a **mode byte**: bit 0
  `privateSize`, bit 1 `crossDevices`, bits 2-7 zero. `load` takes the `ScanOptions` (or both flags) and rejects a
  mismatch of the whole byte (rule 4). `advance` already compares bytes 0..<9 and keeps working. Header offsets do
  not move.
- **[Change] (#15)** `ScanStats` are not stored, so after an update the denied, mount, dataless and firmlink counts
  are zero or count only what the update itself re-read, and the CLI hides the `skipped` line on incremental runs
  (`Scan.swift:139`). The counters are totals, not per directory, so an update cannot keep them exact (a denied
  directory re-read twice would count twice). Change:
  - Store the last full scan's `ScanStats` as 8 × i64 in the order of `ScanStats.merge` (`openErrors`,
    `entryErrors`, `hardlinkDupes`, `datalessDirs`, `datalessLogical`, `mountsSkipped`, `firmlinksSkipped`,
    `cloneDupes`) followed by `fullScanStart` i64, inserted after `uncertainBytes` (offset 37, 72 bytes;
    `volumeUUID` moves to offset 109). `eventIdOffset` stays 13.
  - An update leaves these stored counters unchanged (`apply` stops adding to `tree.stats`; it keeps its own counts
    in `UpdateReport`).
  - On incremental runs `scan -v` shows the line as last-known:
    `skipped (as of full scan at 12:05)  denied … · errors … · …`, with `denied` replaced by the exact current
    count of live `unreadable` nodes.
- **[Change] (#15)** `DiskTree.nodes` is mutated by `Incremental` without a lock; a reader on another thread during
  an update races. Rule: a tree passed to `Incremental.update` or `Snapshot.save` is owned by that call; a reader
  that must not wait takes `let view = tree.nodes` (copy-on-write, consistent) beforehand. Enforced by a
  `Mutex<Bool>` "busy" flag in `DiskTree`, set by `update`/`save`; a second concurrent call is a
  `preconditionFailure`. `nodes` stays `public internal(set)`.
- **[New]** Version 6 carries both changes (mode byte bit 1, stats block). Version 5 files are rejected (rule 3) and
  rebuilt by one full scan, as with earlier versions.

**As built (#5): format 6.** The header is version 5's with byte 8 as the mode byte; offsets 0–36 do not move
(`eventIdOffset` 13, `advance` compares bytes 0..<9). After the aliases the body is a list of **sections**:

| Field | Type | Notes |
|---|---|---|
| `tag` | u32 | `0` end · `1` nodes · `2` hard links · `3` clone families · `4` mount points |
| `size` | u64 | payload bytes; `≤` bytes left in the file |
| payload | | record layouts as in §6.2, each table starting with its u32 count |

- Mount-points payload: count u32, then per record `parent` i32 (a node id) · `name` string (not empty): a child of
  `parent` that the scan skipped because another volume is mounted on it (`DiskTree.mountPoints`).
- The file ends with tag 0, size 0. Load rules replacing 7–14 of §6.4: each known section exactly once; `nodes`
  before any other (they refer to its ids); all four present; each payload read exactly to its `size`; an unknown tag
  is skipped, unless bit 31 (`mustUnderstand`) is set, which rejects the file. The count bounds stay (hard links now
  bounded too, 40 bytes per record; clone families use 28).
- Room for later changes without a version bump before v0.2.0: #15 adds its `ScanStats` + `fullScanStart` as a new
  optional section (tag 5, 72 bytes) instead of moving `volumeUUID` (the header text above for #15 is superseded); a
  file without it simply has no last-known stats. #33 changes only the file name. A change that older format-6
  readers must not ignore uses a tag with bit 31 set.
- `load(rootPath:options:)` compares the whole mode byte with `privateSize | crossDevices << 1`; the
  `load(rootPath:privateSize:crossDevices:)` form defaults `crossDevices` to false (`list`/`clean` unchanged).
- `advance` also refuses a tree that an update changed (`DiskTree.changedSinceSave`, set when `apply` does any work,
  cleared by `save`): a mount or unmount changes the tree with 0 events, so `report.events == 0` no longer proves the
  tree unchanged.

## 7. Update failures

### 7.1 Cases

**[Exists]** `UpdateFailure` (`Incremental.swift:20-53`). Every case leads to a full scan in all commands; the
partly updated tree is dropped and never saved.

| Case | Raised when | `description` |
|---|---|---|
| `rootUnreadable(errno:)` | `lstat(root)` fails; or the root's re-read or rescan cannot open it | `root unreadable (<strerror>)` |
| `volumeChanged(expected:found:)` | stored UUID empty or ≠ the root's current volume UUID | `volume changed (<a> -> <b>)`, empty shown as `unknown` |
| `historyUntrusted(flags:path:)` | a lost-history flag (section 4.3) | `history untrusted (<flags, comma-separated> at <path>)` |
| `historyTimeout(seconds:)` | no `HistoryDone` within 30 s | `history replay timed out after 30 s` |
| `barrierTimeout(seconds:)` | no barrier event within 2 s after creating it | `barrier event timed out after 2 s` |
| `streamFailed(String)` | section 4.5 | `FSEvents stream failed: <why>` |
| `unattributedHardLink(paths:)` | strict mode, section 5.7 | `unattributed hard link: <first 5 paths> (+N more)` |
| `firmlinksChanged` | `aliases(for: root)` ≠ stored aliases | `firmlinks changed` |
| `dataVolumeRoot` (#5) | root lies on the data volume and holds a firmlink target below it (checked first) | `incremental updates are not supported for a data-volume root that holds firmlinked folders` |

### 7.2 What the user sees

**[Exists]** In every case the progress line (`Scanning`) stays up while the update and then the full scan run;
the result is a full scan's.

| Case | `fil scan` | `fil scan -v` | `--porcelain` | `list` / `clean` |
|---|---|---|---|---|
| any | header ends `· full scan` | `timing … [full scan (incremental not usable: <description>)]` | `mode=full` | nothing; with `--timings`: `(not usable: <description>; full scan)` on stderr |
| `unattributedHardLink` | also `  unattributed hard link: <path>` per path (≤ 20), before the header | same | not printed | cannot happen (tolerant) |
| `rootUnreadable` from `lstat` | the full scan's `lstat` fails too and throws; the error reaches top-level code in `main.swift` uncaught and the process traps | same | same | same |
| `historyTimeout` | as "any", after a 30 s wait | same | same | same |

**[New]** `rootUnreadable` from `lstat`: `runScan` and `runCleanup` catch the full scan's `POSIXError` and call
`fail("fil: cannot read <path>: <strerror>")` (exit 1) instead of trapping.

As built (#1): the message is `fil: <path>: <strerror>` (chapter 05 §1.1), not `fil: cannot read <path>: …`. A root that
`lstat` can read but `open` cannot is not an error: `unreadable=1`, exit 0, as before.

**[New]** `historyTimeout` costs 30 s before a full scan starts. `scan -v` prints
`incremental not usable: history replay timed out after 30 s` (as today); no change to the limit, but section 11
asks for a test.

## 8. Clone, hard-link and firmlink invariants across updates

### 8.1 Hard links

**[Exists]** After every update each multiply-linked inode inside the tree is counted exactly once, in its owner
directory, with its current sizes, as in a full scan: re-read directories forget and re-claim (5.5), changes seen
from a non-owner are applied as drift (5.5), lost owners hand over to a remaining link (5.5), and unknown old links
fail (strict) or are counted as uncertain (tolerant) (5.7). Tests: `IncrementalFSEventsTests.swift` scenarios
`hardlink: *`.

### 8.2 Clones

**[Exists]** Each clone family is counted once in `cloneaware`, preferably in the original's directory: forget and
re-claim (5.5), orphans (5.5), adoption of originals cloned after the snapshot (5.6), `applyPreferredOriginals`.

### 8.3 Strict runs on a tolerant snapshot

**[New]** `list`/`clean` (tolerant) and `fil scan ~` (strict) share the home folder's snapshot. A tolerant update
can leave `uncertainBytes > 0`: some bytes may be counted twice. A later strict `scan` loads that tree and, if its
own update succeeds, prints its sizes as exact: `--porcelain` omits `uncertain=` in strict mode
(`Scan.swift:114`), so a script cannot tell. Change: in strict mode `runScan` does not use a loaded tree whose
`uncertainBytes > 0` (full scan; `-v` mode text `full scan (snapshot has uncertain bytes)`). A full scan resets
`uncertainBytes` to 0 and the next tolerant run starts clean.

### 8.4 Firmlinks

- **[Exists]** `tree.aliases` (the data-volume directories the tree reaches through a firmlink instead,
  `FirmlinkTable.aliases(for:)`) are stored in the snapshot and compared on every update (`firmlinksChanged`).
- **[Exists]** Path rewriting, `[FirmlinkTable.Alias].translate` (`Firmlinks.swift:109-115`): an event path that
  starts with an alias's `dataPath`, followed by end or `/`, becomes `source + rest`; then prefixes are matched.

| Root | Alias / prefix | Event path | Mapped to |
|---|---|---|---|
| `/` | alias `/System/Volumes/Data/Users` → `/Users` | `/System/Volumes/Data/Users/code/x` | `Users/code/x` |
| `/` | none (not an alias) | `/System/Volumes/Data/.Spotlight-V100` | `System/Volumes/Data/.Spotlight-V100` |
| `/Users/code` | twin prefix `/System/Volumes/Data/Users/code` | `/System/Volumes/Data/Users/code/x` | `x` |
| `/private/tmp/t` | `realpath` prefix (same) and twin | `/System/Volumes/Data/private/tmp/t/a` | `a` |

- **[Exists]** Re-reads and rescans use `tree.exclusions` (from the aliases), so an update never walks an alias.

## 9. Last-known results

- **[Exists]** The CLI never prints a last-known result; it prints nothing from a snapshot until the update
  succeeded, then either the updated tree or a fresh full scan.
- **[New]** Rules for any output that shows sizes before or without a successful update (the `skipped` line of
  section 6.5 is the first user):
  1. Last-known values come from the snapshot file or from values copied before `Incremental.update` starts. The
     tree object after an `UpdateFailure` is partly updated and is neither current nor last-known: never show it.
  2. The label is `Results from HH:mm` (24-hour, local time) from the snapshot's `scanStart`; if that is not today,
     `Results from 17 Oct 12:05`. For stats: `as of full scan at HH:mm` from `fullScanStart`.
  3. The label sits on the same line as the values and is not dimmed away under `--no-color`; `--porcelain` never
     prints last-known values.
  4. Once the update or full scan finishes, the current values replace the labelled ones; a failed full scan
     leaves the label in place.

## 10. Costs

- **[Exists]** Load: one mapped read, O(nodes + links + families), then `computeTotals` (one reverse pass).
- **[Exists]** Update: history replay (bounded by 30 s + 2 s), then work in re-read and rescanned directories,
  plus O(tree) in `forget` and `affected` until #16.
- **[Exists]** Save after a change: O(tree) (`compact` + encode + atomic write); after no change: one 16-byte
  `pwrite`.

## 11. Tests

- **[Exists]** `ScanCoreTests.swift:101-133`: round trip; rejection on other `privateSize`, other root, truncated
  file, garbage. `IncrementalFSEventsTests.swift`: incremental equals full scan and `du` for add, delete tree, nested
  new dirs, grow, rename dir, move file, delete 1 of 1000, hard-link scenarios, rapid changes; tolerant mode;
  strict unattributed paths; no changes + `advance`; chained updates; permission revoked/restored; other root.
  `AccountingTests.swift`: clone/firmlink updates and `relativeComponents` with aliases.
- **[Change] (#20)** Add, for this chapter: Mount/Unmount under the root (with the #4 fix, the result equals
  `--full`); each of `historyUntrusted` (inject an event with `KernelDropped` through a test seam on the callback),
  `historyTimeout`/`barrierTimeout` (injectable limits), `volumeChanged`, `rootUnreadable`; snapshot rejection on
  version and mode-byte mismatch (including `crossDevices` after #5); case-only and NFC/NFD renames; invalid UTF-8
  names in a saved snapshot.

## As built

- #4 (2026-10-18): two facts the chapter did not know. (1) `getattrlistbulk` returns, for a mount point, the
  `ATTR_CMN_DEVID` of the covered directory, so the §8 check never skipped mount points and even `--full` entered
  them. Listings now flag mount points (mount-status attribute) and take their device from one `lstat` each, as
  `du -x` does; `fil scan / --full` no longer enters `/dev`, `/System/Volumes/VM`, `Preboot`, `/Volumes/*`, autofs,
  NFS or cryptex mounts, so its total drops (correctly) and `mountsSkipped` rises. (2) FSEvents history never holds
  Mount/Unmount events. `checkOwnDevice`/`EXDEV` is built as specified; each update also reads the mount table once
  (`getfsstat`) and rescans tree folders that became mount points. "Unmount needs nothing more" is wrong: a folder
  uncovered by an unmount is not seen until its parent gets an event, and its contents are missing. Fixed with
  snapshot format 6 in #5 (skipped mount points recorded and compared with `getfsstat` on every update).
- #5 (2026-10-18): format 6 as in §6.5 "As built (#5)". Skipped mount points are recorded from listings (children
  with `DIR_MNTSTATUS_MNTPOINT` on another device; other device mismatches are not recorded, so a record is always
  something `getfsstat` lists) and from update reads that end in `EXDEV`. A directory's records are dropped whenever it
  is re-read, rescanned, emptied or removed (like the hard-link `forget`) and re-made by the read; records under dead
  nodes are dropped and `compact` remaps them. `Incremental.mountChanges` reads `getfsstat` once per update and
  returns `mounted` (tree folders now mount points → full rescan, as for #4) and `uncovered` (parents of records not in
  the mount table → shallow re-read, which finds the uncovered folder as a new directory and walks it). If
  `getfsstat` fails, every record's parent is re-read. A tree with records but no event still runs `apply`.
  Checked: `fil scan /private/var/run` records 6 cryptex/system mounts and the next runs re-read nothing; `fil scan /`
  (17 mounts skipped) re-reads no more directories than its events ask for.
- #5 review fixes (2026-10-18): (1) the mount table names a mount point by its firmlink path; for a root given by its
  data-volume path (or the data volume itself) `mountChanges` rewrites such names with
  `FirmlinkTable.dataVolumePath` before matching (chosen over adding prefixes: it also covers a root at
  `/System/Volumes/Data`, where no single prefix maps). (2) A record not found in the table is called gone only if
  `lstat(parent path + name)` no longer shows another device (one syscall per unmatched record). (3)
  `UpdateReport.treeChanged` (a directory was read, walked or removed) decides `up to date from snapshot`,
  `advance` (`changedSinceSave` is set only then) and the `list`/`clean` advance; the change count is
  `events + mountChanges`, and `-v` shows `N mount changes` when non-zero. (4) Idle runs reported 1 event: the
  creation/removal of our barrier directories is reported on the temporary folder, their parent, and replayed by
  the next run. `UpdateReport.events` now counts only events inside the tree (§2's "raw event count" and §3's
  "including ones outside the root" are superseded); `FIL_TIMINGS=1` prints every replayed event path.
- #5 second review (2026-10-18): fseventsd reports changes under a data-volume root by their firmlink path, so
  every event of such a root was dropped (a new file or a replaced root went unseen). `rootPrefixes` now adds the
  firmlink spelling of a root under a firmlink target (`FirmlinkTable.firmlinkPath`, the reverse of
  `dataVolumePath`), for events and the mount table alike. A root at `/System/Volumes/Data` itself has no single
  firmlink spelling: its mount-table names are still rewritten in `mountChanges`, but its events cannot be mapped,
  so `Incremental.update` refuses it first with the new `UpdateFailure.dataVolumeRoot` (added to §7.1). The same
  holds for any data-volume root that holds a firmlink target below it without being inside one
  (`/System/Volumes/Data/usr` holds `usr/local`, `/System/Volumes/Data/System/Library` holds `System/Library/Caches`):
  changes there arrive as `/usr/local/...`. `FirmlinkTable.holdsFirmlinkTargets` decides; such roots always get a
  full scan, never stale sizes shown as current. Roots inside a target (`.../private/tmp/t`) are updated as before.

## Glossary additions

- **event id** — FSEvents id stored in the tree (`DiskTree.eventId`); replay starts after it.
- **barrier event / barrier directory** — the file `barrier` created in `Fil-fsevents.XXXXXX` under the temp folder;
  its event closes the replay and its id becomes the next event id.
- **history / live / finished phase** — `EventHistory.Phase`.
- **lost-history flags** — `UserDropped`, `KernelDropped`, `EventIdsWrapped`, `RootChanged`.
- **shallow re-read** — one directory listed again, not its subtree (`shallow`, `UpdateReport.dirsRead`).
- **full rescan / subtree walk** — a directory and everything below walked again (`full`, `newDirs`, `readable`;
  `UpdateReport.subtreesScanned`).
- **kill / dead node** — `parent = DirNode.dead` (−2); dropped by `compact`.
- **affected** — directories whose registry records are forgotten in an update.
- **drift** — size change of a hard-linked file seen from a non-owner directory.
- **orphan** — registry entry whose owner was forgotten while other links or members remain.
- **adopt original** — `CloneRegistry.adopt`, section 5.6.
- **unattributed hard link** — multiply-linked file older than `scanStart` with no record.
- **strict / tolerant hard links** — `ScanOptions.strictHardlinks`.
- **uncertain bytes** — `DiskTree.uncertainBytes`, porcelain `uncertain=`.
- **root prefixes / data-volume twin** — `Incremental.rootPrefixes`.
- **advance** — `Snapshot.advance`, header-only update of event id and scan start.
- **mode byte** — header byte 8 (bit 0 `privateSize`, bit 1 `crossDevices` after #5).
- **last-known result** — sizes shown with a `Results from HH:mm` label, section 9.
- **`Snapshot.LoadFailure`**, **`DirOutcome` `EXDEV` / `checkOwnDevice`**, **`fullScanStart`** — new in this chapter.
