# 01 Scan engine

The full scan: how `fil scan` turns a directory into a `DiskTree`. This chapter covers the directory reader,
the parallel workers, the `DiskTree` layout and its invariants, the hard-link rules, cloud placeholders, the
device boundary, error accounting (`unreadable`, denied, `entryErrors`, `openError`), `ScanStats`, naive mode,
engine timings and the performance budget. Size rules for clones and firmlinks are in
[02 Size accounting](02-size-accounting.md); the FSEvents replay (incremental update) and the snapshot format are in
[03 Incremental and snapshots](03-incremental-and-snapshots.md) and only appear here where the scan engine serves
them.

Sources: `Sources/ScanCore/Scanner.swift`, `Sources/ScanCore/DiskTree.swift`, `Sources/ScanCore/Timings.swift`,
with the CLI side in `Sources/fil/Scan.swift`, `Sources/fil/main.swift` and `Sources/fil/Permissions.swift`.

Status tags: **[Exists]** is in the code today (file reference given); **[Change]** is in the code and changes
as described here (reason and issue given); **[New]** does not exist yet.

## 1. Goals and hard rules

- **[Exists]** One `getattrlistbulk` loop per directory, parallel workers (default 8). No syscall and no heap
  allocation per file on the hot path; work per directory (one `open`, one `close`, one lock round-trip, one
  `String` per child directory name) is allowed. (`Scanner.swift`, `DirReader.read`)
- **[Exists]** `alloc` of the root equals `du -skx <dir>` x 1024 exactly, for any tree the user can fully read.
  Check: `.build/release/fil scan <dir> --full --top 0` vs `du -skx <dir>`; `scripts/verify.sh` automates it.
- **[Exists]** Hard links count once; `SF_DATALESS` placeholders are never entered or downloaded; the scan never
  crosses into another device.
- **[Exists]** Symlinks are never followed (`O_NOFOLLOW` on open, `FSOPT_NOFOLLOW` on read; a symlink counts as
  a file with its own allocation).

## 2. Flow of a full scan

`Scanner.scan(_ path:, options:, progress:)` (`Scanner.swift:26`) **[Exists]**:

| Step | Action | Notes |
|---|---|---|
| 1 | `preventCloudDownloads()` | `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`: no access in this process can materialize a dataless file. |
| 2 | `lstat(path)` | Failure throws `POSIXError(errno)` (fallback `.EIO`). `st_dev` becomes `rootDev`. |
| 3 | `scanStart = nowNanoseconds()` | `CLOCK_REALTIME`, ns since epoch. Used as the hard-link birth cutoff of the next incremental update. |
| 4 | `eventId = FSEventsGetCurrentEventId()` | Taken **before** walking: anything that changes during the walk is replayed by the next update. |
| 5 | Build `DiskTree` | `nodes = [DirNode(parent: -1, name: path)]`, `volumeUUID = FSEventsCopyUUIDForDevice(rootDev)` as string (`""` if none), empty `HardlinkRegistry` and `CloneRegistry`, `aliases = options.firmlinks.aliases(for: path)`. |
| 6 | `rescanSubtrees([0], ...)` | The parallel walk (section 4). Failed roots are ignored in a full scan: an unreadable root stays as an empty node. |
| 7 | `applyPreferredOriginals(tree)` | Moves each clone family to its original's directory (chapter 02). |
| 8 | `computeTotals()` | One reverse pass (section 5.4). |

The CLI (`Scan.swift`) then saves the snapshot (`Snapshot.save`, which calls `DiskTree.compact`) unless an
incremental update changed nothing, in which case `Snapshot.advance` rewrites only `eventId` and `scanStart`.

`rescanSubtrees(_ ids:, in:, options:, progress:)` (`Scanner.swift:61`) **[Exists]** is shared by the full scan
and the incremental update. It runs one `ParallelScan` over the given existing nodes (whose old descendants must
already be dead), copies the roots' own sizes and `unreadable` flag back, bulk-appends every discovered node with
its parent remapped (`local < rootCount ? ids[local] : base + local - rootCount`), merges `ScanStats`, and returns
`[id: errno]` for roots whose directory is gone (`DirOutcome.isGone`).

## 3. Directory reader (`DirReader`)

### 3.1 Open

**[Exists]** `open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` on the absolute path built by
appending `"/" + name` to the parent's path (`"/"` root uses `""` as base). On failure: `opened = false`,
`openError = errno`, `stats.openErrors = 1`, nothing else is read.

**[Change] (#6)** Names are decoded with `String(cString:)`, which replaces invalid UTF-8 with U+FFFD; the path
built from that name does not exist, the child fails with `ENOENT`, and its whole subtree is lost (and, because
`ENOENT` is "gone", silently). New rule:

- When parsing a child directory name, decode with `String(validatingCString:)`. If it returns a value, nothing
  changes. If it returns nil (invalid UTF-8), store the display name with U+FFFD in `DirNode.name` **and** the raw
  bytes in a side table `DiskTree.rawNames: [Int32: [UInt8]]` (rare: no cost for valid names).
- `WorkItem.path` and every path handed to a syscall are built from bytes (`path(of:)` gets a byte variant
  `cPath(of:) -> [CChar]` that prefers `rawNames`). Display paths keep using `path(of:)`.
- `openat(parentFd, rawName, ...)` was considered and rejected: the LIFO queue would have to keep one parent fd
  open per queued directory (fd exhaustion on wide trees).
- Snapshot: `rawNames` persisted in format 6 after the clone families: `u32 count`, then per entry
  `id i32 | u32 length | bytes` (chapter 02, section 3.5).
- Test: a fixture directory whose name is the bytes `0x66 0xFF 0x6F`, containing a 100 KB file; root `alloc`
  equals `du -skx` x 1024 and `openErrors == 0`.

### 3.2 Attribute request

**[Exists]** `attrlist` with `bitmapcount = ATTR_BIT_MAP_COUNT` and options
`FSOPT_NOFOLLOW (0x1) | FSOPT_ATTR_CMN_EXTENDED (0x20)`. `FSOPT_PACK_INVAL_ATTRS` is **not** set, so an attribute
the kernel cannot return is omitted from the record and its bit is cleared in `ATTR_CMN_RETURNED_ATTRS`; the
parser checks every bit before reading.

Each record in the buffer is: `u32 length`, then the fields below in this exact order (sys/attr.h bit order,
except that `ERROR` always follows `RETURNED_ATTRS`). All loads are `loadUnaligned`.

| # | Group | Attribute | Bit | Bytes | Type | Requested | Used for |
|---|---|---|---|---|---|---|---|
| 1 | common | `ATTR_CMN_RETURNED_ATTRS` | 0x80000000 | 20 | `attribute_set_t` | always | which fields follow |
| 2 | common | `ATTR_CMN_ERROR` | 0x20000000 | 4 | `u32` | always | non-zero: entry dropped, `entryErrors += 1` |
| 3 | common | `ATTR_CMN_NAME` | 0x00000001 | 8 | `attrreference_t` | always | name = `fieldAddress + attr_dataoffset`, NUL-terminated |
| 4 | common | `ATTR_CMN_DEVID` | 0x00000002 | 4 | `dev_t` | always | device boundary (default `rootDev` if absent) |
| 5 | common | `ATTR_CMN_OBJTYPE` | 0x00000008 | 4 | `fsobj_type_t` | always | `VDIR`, `VREG`, other |
| 6 | common | `ATTR_CMN_FLAGS` | 0x00040000 | 4 | `u32` | always | `SF_DATALESS` (0x40000000) |
| 7 | common | `ATTR_CMN_USERACCESS` | 0x00200000 | 4 | `u32` | only `Config.userAccess` (incremental re-reads) | `R_OK|X_OK` on child dirs (default both if absent) |
| 8 | common | `ATTR_CMN_FILEID` | 0x02000000 | 8 | `u64` | always | hard-link key; clone original test |
| 9 | file | `ATTR_FILE_LINKCOUNT` | 0x00000001 | 4 | `u32` | always | `> 1` means hard-linked (default 1) |
| 10 | file | `ATTR_FILE_ALLOCSIZE` | 0x00000004 | 8 | `off_t` | always | `alloc`, `realAlloc` |
| 11 | file | `ATTR_FILE_DATALENGTH` | 0x00000200 | 8 | `off_t` | always | `logical` |
| 12 | fork (CMNEXT) | `ATTR_CMNEXT_PRIVATESIZE` | 0x00000008 | 8 | `off_t` | only `--private` | replaces `alloc` (not `realAlloc`) |
| 13 | fork (CMNEXT) | `ATTR_CMNEXT_CLONEID` | 0x00000100 | 8 | `u64` | always | clone family key |
| 14 | fork (CMNEXT) | `ATTR_CMNEXT_EXT_FLAGS` | 0x00000200 | 8 | `u64` | always | `EF_SHARES_ALL_BLOCKS` (0x40) |

Directories carry no file or fork attributes; their record ends after field 8. The buffer is
`DirReader.bufSize = 256 * 1024` bytes, 16-byte aligned, allocated once per worker (`DirReader.init`) and freed
when the worker exits. `CLONEID` and `EXT_FLAGS` are inode fields and cost about 3% (chapter 02);
`PRIVATESIZE` walks extents and costs about 70%, hence opt-in.

**[Change] (#48)** A FAT (msdos) listing returns no `ATTR_FILE_ALLOCSIZE`, so every file counts 0 bytes. Add
`ATTR_DIR_ALLOCSIZE` (0x00000008) and `ATTR_DIR_DATALENGTH` (0x00000020), 8 bytes each in that order, to every
request; directory records then end after them. `DirOutcome` carries each child directory's own allocation, and
a missing `ALLOCSIZE` (file or directory) is replaced by the data length rounded up to the allocation unit
(chapter 02 §1.1). Cost: two fields per directory record, no syscall.

### 3.3 Read loop

**[Exists]** `while true { count = getattrlistbulk(fd, &al, buf, bufSize, opts) }`: `count == 0` ends the
directory; `count < 0` adds 1 to `entryErrors` and ends the directory; otherwise each of `count` records is
parsed and the pointer advances by its `length`. Firmlink exclusions for this directory are looked up once
(`config.exclusions[path]`, nil when the table is empty).

**[Change] (#7)** A `getattrlistbulk` failure mid-directory and a per-entry `ATTR_CMN_ERROR` both under-report
silently (the directory still has `opened == true`; a dropped child directory is never walked). New rule:

- `count < 0` with `errno == EINTR`: call again, up to 3 consecutive retries; entries already parsed stay.
- Any other `count < 0`, an `EINTR` after 3 retries, or a non-zero `ATTR_CMN_ERROR`: `entryErrors += 1` (as
  today) and `DirOutcome.incomplete = true`. Parsing continues with the next record where possible.
- `DirNode` gains `incomplete: Bool`, stored in the existing flags byte of the snapshot (bit 1; bit 0 is
  `unreadable`). Its own sizes are kept (they are a lower bound); it is not walked again until it is re-read.
- The CLI counts incomplete directories in `unreadable=` (no new porcelain field; the count means "folders whose
  size is a lower bound") and lists them in the warning block with the reason "could not be read completely".
- `--verbose` keeps showing `errors <entryErrors>`.

### 3.4 Per-entry decision

**[Exists]** (`DirReader.parseEntry`, `Scanner.swift:321`). Evaluated in this order:

| Condition | Effect |
|---|---|
| `ATTR_CMN_ERROR != 0` | `entryErrors += 1`; entry dropped. |
| `type == VDIR`, `dev != rootDev`, `!options.crossDevices` | `mountsSkipped += 1`; not entered. |
| `type == VDIR`, `flags & SF_DATALESS` | `datalessDirs += 1`; not entered. |
| `type == VDIR`, name in `exclusions[path]` | `firmlinksSkipped += 1`; not entered (chapter 02). |
| `type == VDIR`, otherwise | `childDirs.append(name)` (with its own allocation after #48); with `userAccess` and access lacking `R_OK` or `X_OK`, also `deniedChildDirs.append(name)`. A directory is never a file: no sizes. |
| file, `flags & SF_DATALESS` | `datalessLogical += logical`, `files += 1`; nothing added to `alloc`, `logical` or `cloneAware`. |
| file, `links > 1`, `type == VREG` | Hard-link claim (section 6): nil defers it to `deferredLinks`; false adds 1 to `hardlinkDupes` and counts nothing; true adds `realAlloc` to `cloneAware` and falls through to the sums. |
| file, `EF_SHARES_ALL_BLOCKS`, `cloneID != 0`, `type == VREG` | Appended to `cloneMembers` (`CloneMember(cloneID, alloc: realAlloc, isOriginal: cloneID == fileID)`); `cloneAware` decided by the `CloneRegistry` (chapter 02). |
| file, otherwise | `cloneAware += realAlloc`. |
| every counted file | `alloc += alloc` (private size with `--private`), `logical += logical`, `files += 1`. |

"file" means any non-directory object: regular files, symlinks, sockets, FIFOs, devices. Only `VREG` takes part
in hard-link and clone deduplication.

**[Exists], limitation** A multiply-linked non-regular object (a hard-linked symlink or FIFO, which APFS
allows) is counted once per link. `du` counts it once. The difference is a few bytes per such object and has
not been seen in practice; no change planned.

### 3.5 `DirOutcome`

**[Exists]** (`Scanner.swift:222`)

| Field | Type | Meaning |
|---|---|---|
| `alloc` | `Int64` | Sum of counted files' `ATTR_FILE_ALLOCSIZE` (or `PRIVATESIZE` with `--private`). |
| `logical` | `Int64` | Sum of `ATTR_FILE_DATALENGTH`. |
| `files` | `Int64` | Files counted here, dataless ones included. |
| `cloneAware` | `Int64` | Clone-aware bytes, without the full clones in `cloneMembers`. |
| `cloneMembers` | `[CloneMember]` | Full-clone files, claimed by the caller in one `CloneRegistry.claim`. |
| `childDirs` | `[String]` | Child directories to walk. |
| `deniedChildDirs` | `[String]` | Child directories the user may not list (only with `Config.userAccess`). |
| `deferredLinks` | `[(inode, alloc, logical, cloneAware)]` | Hard links whose claim returned nil (incremental re-reads). |
| `stats` | `ScanStats` | This directory's counters. |
| `opened` | `Bool` | `open` succeeded. |
| `openError` | `Int32` | errno of the failed `open`, 0 if opened. |
| `isGone` | computed | `!opened && openError in {ENOENT, ENOTDIR, ELOOP}`: the directory no longer exists as a directory. |

## 4. Workers (`-j`)

### 4.1 Model

**[Exists]** `ParallelScan` (`Scanner.swift:112`), one per `rescanSubtrees` call.

- `options.threads` `Thread`s, each with `stackSize = 1 MB` and `qualityOfService = .userInitiated`. Default
  `ScanOptions.threads = 8`: measured on M-series with APFS, throughput plateaus around 8 (the kernel is the
  limit beyond that).
- One `NSCondition` (`cond`) guards `nodes`, `queue`, `active`, `finished`, `stats` and `failedRoots`.
- The queue is a LIFO stack of `WorkItem(id: Int32, path: String)`: depth-first order keeps it small. Initial
  items are the roots in reverse order, so root 0 is taken first.
- Worker loop: lock; while the queue is empty, exit if `active == 0` (incrementing `finished` and broadcasting),
  otherwise wait; pop, `active += 1`, unlock; read the directory **without the lock**; claim clone members (one
  `CloneRegistry` lock per directory with clones); update `ScanProgress`; lock; record the outcome in
  `nodes[item.id]`, merge stats, append one `DirNode` and one `WorkItem` per child directory; `active -= 1`;
  `broadcast` if more than one child was queued or the scan is finished, `signal` if exactly one was queued.
- `run()` starts all threads and waits on `cond` until `finished == threads`.
- Local ids: `0..<roots.count` are the roots; nodes found below are appended. `globalId(local)` maps a local id
  to the id it will have in the tree, so registries record final ids during the walk.
- A worker's hard-link claim closure calls `HardlinkRegistry.vet` then `HardlinkRegistry.claim` per
  multiply-linked file (section 6).

### 4.2 Live progress

**[Exists]** `ScanProgress` (`Scanner.swift:8`): three `Atomic<Int64>` (`dirs`, `files`, `bytes`), updated with
`.relaxed` ordering once per directory (`dirs += 1`, `files += out.files`, `bytes += out.cloneAware`, after
clone claims). Readable from any thread. Not updated by the incremental re-read path.

### 4.3 Worker count validation

**[Change] (#10)** `ScanOptions.init` clamps `threads` to `max(1, threads)`, but `threads`
is a public `var` and the CLI assigns `-j N` directly (`Scan.swift:22`). `fil scan <dir> --full -j 0` starts zero
workers, returns at once and reports an empty tree as a valid result (verified: `alloc=0 files=0 dirs=1`), and
the empty tree is saved as the snapshot. In an incremental update, `readDirectories` would run zero workers and
apply default `DirOutcome`s, zeroing every re-read directory. New rule:

- `ScanOptions.threads` clamps on every set (`didSet { threads = min(max(threads, 1), 64) }`).
- The CLI rejects a non-integer or out-of-range value with a usage error (exit 2, per #10):
  `usageError("-j expects a number from 1 to 64", help: scanHelp)`. Exit codes are specified in the CLI chapter.

### 4.4 Lock contention

**[Exists]** Per directory: one `cond` round-trip, at most one `CloneRegistry` lock. Per multiply-linked file:
one `HardlinkRegistry` lock in `claim` (and none in `vet` during a full scan: it returns before locking when
`birthCutoff` is nil).

**[Change] (#18)** Hard-link claims take the registry-wide lock per file; trees with many hard links (Homebrew
Cellar, pnpm store) contend. New rule: `DirReader` never calls the claim closure from `parseEntry`; every
multiply-linked `VREG` goes to `deferredLinks` (sizes not yet added). After the read, the worker calls
`HardlinkRegistry.claim(_ batch: [(inode, alloc, logical, cloneAware)], by: gid) -> [Bool]` and `vet` for the
same batch, each under **one** lock acquisition, then adds the claimed entries to `alloc`, `logical`,
`cloneAware`, `files` and counts the rest in `hardlinkDupes`. This is the same path the incremental re-read
already uses (deferral), so `DirReader` loses its claim parameter. Acceptance: no change in any total; on a tree
of 200k hard links, `-j 8` full scan not slower than today.

## 5. `DiskTree`

### 5.1 `DirNode` layout

**[Exists]** (`DiskTree.swift:6`). One record per directory; files are never stored, they roll up into their
directory. `MemoryLayout<DirNode>.stride == 96` bytes; names of up to 15 UTF-8 bytes are stored inline in the
`String`, longer names add one heap allocation.

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `parent` | `Int32` | Parent id; `-1` for the root; `DirNode.dead == -2` for a removed node. |
| 4 | `unreadable` | `Bool` | Exists but could not be listed; own sizes 0, no children. In the padding after `parent`. |
| 8 | `name` | `String` | One path component; the root's name is the full root path. |
| 24 | `ownAlloc` | `Int64` | Files directly inside: allocated bytes (private bytes with `--private`). |
| 32 | `ownLogical` | `Int64` | Files directly inside: data length. |
| 40 | `ownFiles` | `Int64` | Files directly inside. |
| 48 | `ownCloneAware` | `Int64` | Files directly inside, clone-aware (chapter 02). |
| 56 | `totalAlloc` | `Int64` | Own + all live descendants. |
| 64 | `totalLogical` | `Int64` | Own + all live descendants. |
| 72 | `totalFiles` | `Int64` | Own + all live descendants. |
| 80 | `totalDirs` | `Int64` | Number of live descendant directories (not counting itself). |
| 88 | `totalCloneAware` | `Int64` | Own + all live descendants. |

**[Change] (#7)** Add `incomplete: Bool` at offset 5 (padding; stride unchanged).

**[Change] (#49)** Add `fileID: UInt64` at offset 96 (`ATTR_CMN_FILEID` of the directory; 0 = unknown), so an
update can tell a recreated folder from the old one (chapter 03 §5.2). Stride 96 → 104 bytes (+8 MB per million
folders); no padding is left for it.

### 5.2 `DiskTree` fields

**[Exists]** (`DiskTree.swift:283`), a `final class`.

| Field | Meaning |
|---|---|
| `rootPath` | Scanned path, as given (standardized by the CLI). |
| `rootDev` | `st_dev` of the root; refreshed by each incremental update (device numbers change across reboots). |
| `privateSize` | Scan mode (`--private`); a snapshot of the other mode is never loaded. |
| `nodes` | The flat array. Only appended to, marked dead, or replaced by `compact`. |
| `eventId` | FSEvents id taken before the scan or update started. |
| `volumeUUID` | FSEvents UUID of the root's device. |
| `scanStart` | Wall-clock start (ns) of the scan or update this tree reflects. |
| `stats` | `ScanStats` (section 9). |
| `uncertainBytes` | Tolerant-mode hard-link uncertainty (section 6.3); 0 after a full scan. |
| `aliases` | Firmlink aliases (chapter 02); `exclusions` is derived from them. |
| `hardlinks`, `clones` | `HardlinkRegistry`, `CloneRegistry`. |
| `links` | `ChildLinks`: first-child / next-sibling arrays. |

### 5.3 Invariants

**[Exists]** unless marked.

1. `nodes[0]` is the root: `parent == -1`, `name == rootPath`.
2. For every live node `i > 0`: `0 <= parent < i` (a child's id is always larger than its parent's). The
   snapshot loader rejects a file that breaks this.
3. A dead node has `parent == -2`; every descendant of a dead node is dead. Dead nodes are skipped by totals
   and by child iteration.
4. In a fresh full scan, the children of a directory have consecutive ids (appended in one locked loop). This is
   not guaranteed after an incremental update; nothing may rely on it.
5. `unreadable == true` implies own sizes 0 and no live children.
6. `total* = own* + sum(total* of live children)`; `totalDirs = sum(totalDirs + 1 of live children)`.
7. Each multiply-linked inode in the `HardlinkRegistry` is counted in exactly one live node (its owner); each
   clone family in the `CloneRegistry` in exactly one live node's `ownCloneAware`.
8. Root `totalAlloc == du -skx x 1024` when the scan is not `--private` and the tree has no `unreadable` node,
   no incomplete node, no skipped `SF_DATALESS` directory and no firmlink alias (chapter 02). `du` skips the
   same unreadable directories, so in practice it also holds with them. **[Change] (#48)** Also on a volume
   whose listings omit `ALLOCSIZE` (FAT, exFAT), and counting directories' own clusters (chapter 02 §1.1).
9. `nodes` is not safe to read while a scan or update mutates it (see 5.6).

### 5.4 Totals

**[Exists]** `computeTotals()`: copy own into total for every node, then one pass over ids in descending order
adding each live node into its parent. O(N), one buffer access. `updateTotals(changed:firstNew:)` recomputes only
appended nodes and the ancestor chains of changed nodes (incremental update).

### 5.5 Child links, lookup, compaction

**[Exists]** `ChildLinks` keeps `first[id]` and `next[id]` (`Int32`, -1 = none), extended by `syncLinks()` for
nodes appended since the last call, under `links.lock`. A dead node stays in its old parent's list and is
skipped because its `parent` no longer matches. `forEachChild(of:)` and `child(of:named:)` walk the list;
`node(at:)` resolves a path component by component. `path(of:)` walks parents: O(depth).

`compact()` drops dead nodes with a stable in-place compaction (live order and invariant 2 preserved), builds
`map[old] -> new or -1`, resets `links`, and calls `hardlinks.remap(map)` and `clones.remap(map)`. Run by
`Snapshot.save`.

**[Change] (#17)** `child(of:named:)` is a linear sibling walk and its callers allocate a `String` per path
component; per event in an incremental update it is O(siblings). The fix (a per-parent `[String: Int32]` index in
`ChildLinks`, built once a lookup walks more than 32 siblings, validated by `parent`, cleared by `compact`; and a
`some StringProtocol` parameter so a `Substring` component compares without allocating) is specified in
[03 Incremental and snapshots](03-incremental-and-snapshots.md), section 5.1. `node(at:)` uses the same lookup.

### 5.6 Concurrent access

**[Change] (#15)** `DiskTree.nodes` is `public internal(set)` and the incremental update mutates it in many
steps without a lock; a reader during an update races. Rule (specified in chapter 03, section 6): a tree passed
to `Incremental.update` or `Snapshot.save` is owned by that call; a reader that must not wait takes
`let view = tree.nodes` beforehand (copy-on-write: a consistent copy at no cost) and labels it as last-known. A
`Mutex<Bool>` busy flag in `DiskTree`, set by `update` and `save`, turns a second concurrent call into a
`preconditionFailure`. A full scan builds its tree privately and publishes it only when `Scanner.scan` returns.

## 6. Hard links

### 6.1 Full scan

**[Exists]** (`HardlinkRegistry`, `DiskTree.swift:83`). Only regular files with `ATTR_FILE_LINKCOUNT > 1`. The
registry is `[UInt64: Entry]` keyed by `ATTR_CMN_FILEID`, under one `NSLock`.

| `Entry` field | Meaning |
|---|---|
| `owner: Int32` | Directory that counts the inode; -1 while released (incremental) and not re-claimed. |
| `alloc`, `logical` | Sizes counted (`alloc` is the private size with `--private`). |
| `cloneAware` | `ATTR_FILE_ALLOCSIZE` counted in `ownCloneAware`. Hard-linked files are never deduplicated as clones. |
| `others: [Int32]` | Other directories where a link was seen; never contains `owner`. |

`claim(inode, by: dir, ...)`: unknown inode: record with `owner = dir`, return true (count it). Known, owner is
`dir`: return false (a second link in the same directory). Known, owner released: `dir` becomes owner, sizes
replaced, return true. Known, other owner: add `dir` to `others`, record size drift if the sizes differ, return
false. A false result adds 1 to `hardlinkDupes` and the link counts in no size and not in `files`.

Which directory owns an inode in a full scan depends on worker order. Totals at any directory that contains
every link are deterministic; the split between sibling directories is not (unlike clone families, chapter 02).
**[Exists], accepted.**

Inode keys are not qualified by device. **[Exists], limitation:** `ScanOptions.crossDevices` (no CLI flag)
would let inodes of two devices collide; it must stay unexposed until both registries key by `(dev, inode)`.

### 6.2 Incremental update: unknown old links

**[Exists]** A new link created after the snapshot to a file that was single-link at scan time: the file was
counted in its first directory as a plain file and is not in the registry. When an update meets a
multiply-linked file whose inode is unknown, `vet(inode, alloc:, dirPath:, name:)` costs one
`fstatat(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW)` (only for such entries) and compares `st_birthtimespec` (ns) with
`birthCutoff` (the tree's `scanStart`, set by `beginUpdate`). Born before the cutoff: the file is an
**unattributed hard link**: `unattributed = true`, its `alloc` added once per inode to `unattributedAlloc`, its
path kept (at most `maxUnattributedPaths = 20`). Born after: an ordinary new file.

### 6.3 Strict vs tolerant

| | Strict (default) | Tolerant (`--tolerant-hardlinks`) |
|---|---|---|
| Option | `ScanOptions.strictHardlinks = true` | `false` |
| Unattributed link met | Update fails with `UpdateFailure.unattributedHardLink(paths:)`; the CLI runs a full scan and prints `  unattributed hard link: <path>` per path (human output only). `vet` stops looking after 20 paths. | Counted where met; `unattributedAlloc` added to `DiskTree.uncertainBytes` and to `UpdateReport.uncertainBytes`; `vet` keeps going so every such inode's `alloc` is included. |
| Result | Exact | May count up to `uncertainBytes` twice |
| Porcelain | no `uncertain=` field | `uncertain=<DiskTree.uncertainBytes>` always present |
| Human output | — | yellow line `<size> uncertain (hard links that may be counted twice)` when > 0 |
| Users | `fil scan` | `fil scan --tolerant-hardlinks`; `fil list` / `fil clean` (`Cleanup.swift`) |

**[Exists]** `uncertainBytes` is persisted in the snapshot header, only grows across tolerant updates, and is 0
after a full scan. `UpdateFailure.description` prints the first 5 paths and `(+N more)`.

**[Exists], limitation:** the cutoff compares file birth time (filesystem clock) with `CLOCK_REALTIME` at scan
start; a wall-clock jump backwards between scans can misclassify a file. Accepted.

### 6.4 Registry maintenance cost

**[Change] (#16)** `forget(where:)` and `resolveOrphans()` iterate the whole table on each update, so update
cost scales with the number of hard links in the tree, not with the change. The fix is specified in chapter 03,
section 5.5: both registries keep `byDir: [Int32: [UInt64]]` (keys where the directory is owner, original or in
`others`; stale keys skipped on use); `forget(dirs: Set<Int32>)` replaces `forget(where:)` and touches only those
keys; ownerless keys go into `orphans: Set<UInt64>`, which `resolveOrphans` walks instead of the table.
`remap` stays O(table): it runs only in `Snapshot.save` after `compact`. Engine-side acceptance in addition to
chapter 03's: with `FIL_TIMINGS=1`, lap `apply.forget` stays under 5 ms for a one-file change in a 1 M-file tree
with 100 k hard links.

## 7. Cloud placeholders (`SF_DATALESS`)

**[Exists]**

- The process-wide I/O policy (step 1 of section 2) is set before any scan or update, so no access can trigger a
  File Provider download.
- A directory with `SF_DATALESS` (0x40000000) in `ATTR_CMN_FLAGS` is never entered: `datalessDirs += 1`, no node.
- A file with `SF_DATALESS` counts 1 in `files`, adds its `ATTR_FILE_DATALENGTH` to `datalessLogical`, and adds
  nothing to `alloc`, `logical` or `cloneAware` (it occupies no data blocks; `du` agrees).
- `fil scan --naive` does not set the policy (section 10).

## 8. Device boundary

**[Exists]** `rootDev` is the root's `st_dev`. A child directory whose `ATTR_CMN_DEVID` differs is not entered
(`mountsSkipped += 1`) unless `ScanOptions.crossDevices` (no CLI flag; see 6.1). Files are never mount points, so
only directories are checked. The system and data volumes of the boot volume group report the same device;
firmlinks handle that case (chapter 02). Other APFS volumes (`/System/Volumes/Preboot`, `VM`, `Update`, `xarts`,
`iSCPreboot`, `Hardware`, `/Volumes/*`, cryptex mounts) are skipped by this rule.

**[Change] (#4)** The check runs only on children found in a listing; a directory read on its own (incremental
re-read or rescan root) is never checked. After `hdiutil attach -mountpoint ~/mnt image.dmg`, an update re-reads
`~/mnt` and counts the image as its own files. New rule:

- `DirReader.Config` gains `checkOwnDevice: Bool` (default false). When set, `read` calls `fstat(fd)` after
  `open`; if `st_dev != config.rootDev && !config.options.crossDevices`, it returns `opened = false`,
  `openError = EXDEV`, `stats.mountsSkipped = 1` (not `openErrors`).
- `isGone` includes `EXDEV`, so the update removes the node, which is what a full scan produces (it never creates
  a node for a mount point).
- Set by `Incremental.readDirectories` for every read, and by `ParallelScan` for root items only
  (`item.id < rootIds.count`) when called from an update; false in a full scan (the root defines `rootDev`,
  every other directory was checked by its parent). Cost: one `fstat` per re-read directory and per rescanned
  subtree root, none per file, none in a full scan.
- Rejected (chapter 03): treating `Mount`/`Unmount` events as lost history; any disk plugged in under the root
  would force a full scan.
- Unmount needs no special case: the event maps to the nearest known ancestor, which is re-read and finds the
  directory again on the root device.
- Tests (#20): mount a disk image inside a fixture after the snapshot; the update equals a full scan; unmount;
  the update equals a full scan again.

## 9. Errors, unreadable and `ScanStats`

### 9.1 Outcomes

**[Exists] (#34)** During a full scan, a directory whose `open` fails with `ENOENT`, `ENOTDIR` or `ELOOP`
(`isGone`) vanished after it was listed: it is dropped, not kept as unreadable, and is counted neither in
`unreadable=` nor in the permission warning. Reason: it is not a permission problem and `fil doctor` cannot fix it.
The table below describes the code after #6, #7 and #34.

| Situation | Node | Counters | CLI |
|---|---|---|---|
| `open` fails, `EACCES`/`EPERM` (TCC, POSIX mode, other user) | kept, `unreadable = true`, empty | `openErrors += 1` | counted in `unreadable=`; listed in the warning, classified by `Permissions.classify` as `privacyProtected`, `otherUser` or `noPermission` |
| `open` fails, `ENOENT`/`ENOTDIR`/`ELOOP` (`isGone`) | dead (`parent = DirNode.dead`), also below an update's rescan root; a full scan compacts it away; root of an update read or rescan: removed | `openErrors += 1` | not counted, not listed (`denied` in `-v` still counts it) |
| root `lstat` fails | — | — | `fil scan` exits with the POSIX error |
| root is a symlink or not a directory | root kept, `unreadable` (`ELOOP`/`ENOTDIR`), empty | `openErrors = 1` | `alloc=0 ... unreadable=1`, exit 0; [Change] (#11): resolve with `realpath`, fail when not a directory (CLI chapter) |
| root `open` fails (full scan) | root kept, `unreadable`, empty | `openErrors = 1` | `unreadable=1` |
| `getattrlistbulk` returns -1 (`EINTR`: up to 3 retries) | kept with what was read, `incomplete = true` | `entryErrors += 1` | counted in `unreadable=`; listed, `(could not be read completely)` |
| per-entry `ATTR_CMN_ERROR` | entry dropped, `incomplete = true` | `entryErrors += 1` | as above |
| invalid UTF-8 directory name | display name with U+FFFD, bytes in `rawNames`, opened by bytes | — | — |
| child dir not listable, seen by an update (`deniedChildDirs`) | emptied, `unreadable = true` | — | counted in `unreadable=` |

**[Exists] (#34)** A non-root `isGone` directory is marked dead (`parent = DirNode.dead`) instead of `unreadable`;
`openErrors` still counts it. Before, it was kept `unreadable` and shown in the permission warning as
`noPermission` (its `stat` fails).

"Denied" in `--verbose` output is `stats.openErrors`; `unreadable=` is the number of live nodes with
`unreadable == true` (computed by `Permissions.unreadable(in:)`, one `stat` per such node for the owner).

### 9.2 `ScanStats`

**[Exists]** (`DiskTree.swift:54`). Per directory in `DirOutcome.stats`, merged under `cond`; merged into
`DiskTree.stats` by `rescanSubtrees`.

| Field | Type | Counts | `--verbose` label |
|---|---|---|---|
| `openErrors` | `Int` | directories whose `open` failed | `denied` |
| `entryErrors` | `Int` | `getattrlistbulk` failures + per-entry errors | `errors` |
| `hardlinkDupes` | `Int` | links not counted because another link counts the inode | `hardlinks` |
| `datalessDirs` | `Int` | `SF_DATALESS` directories not entered | `cloud-dirs` |
| `datalessLogical` | `Int64` | logical bytes of `SF_DATALESS` files | `cloud files` |
| `mountsSkipped` | `Int` | child directories on another device | `mounts` |
| `firmlinksSkipped` | `Int` | data-volume directories reached through a firmlink instead | `firmlinked data dirs` |
| `cloneDupes` | `Int` | full-clone files whose family is counted elsewhere | `clone files counted once` |

**[Change] (#15)** `Snapshot.load` does not restore `stats`, so after an incremental update they hold only that
update's re-reads; the CLI therefore hides the "skipped" lines on incremental runs (`Scan.swift:139`). New rule:

- The snapshot stores the `ScanStats` of the last full scan (8 x i64 in `merge` order) and `fullScanStart` (i64),
  after `uncertainBytes` in the header (format 6; layout in chapter 03, section 6).
- An update leaves the stored counters unchanged (`apply` stops adding to `tree.stats`; its own counts go to
  `UpdateReport`). On incremental runs `-v` shows `skipped (as of full scan at HH:MM)  denied ... · ...`, with
  `denied` replaced by the exact live count of `unreadable` nodes.

## 10. Naive mode

**[Exists]** `fil scan [DIR] --naive` (`Scan.swift:40`): the baseline "what most cleaner apps do". A
`FileManager.default.enumerator(at:includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])`
walk, one `resourceValues` call per entry, errors ignored, summing `totalFileAllocatedSize` of non-directories.
Prints one line, `naive  <size>  <files> files  <ms>`, and returns. No hard-link deduplication, no device
boundary, no firmlink rule, no dataless policy, no snapshot, no `--porcelain`. For benchmarks only; its size is
not comparable to `alloc`.

## 11. Engine timings

**[Exists]** `Timings` (`Timings.swift`): with `FIL_TIMINGS=1` in the environment, `Timings.Lap(scope).lap(name)`
prints `[timing] <scope>.<name> <ms with 1 decimal> ms` to stderr, measuring since the previous lap
(`ContinuousClock`). Scopes in use: `update`, `apply`, `save`, `load`. Disabled cost: one `Bool` check per lap.
The CLI's `-v` timing line is separate (`Scan.swift`) and always available.

**[Exists]** (#44) The full scan gets laps too, scope `scan`: `walk` (after `rescanSubtrees`), `originals` (after
`applyPreferredOriginals`), `totals` (after `computeTotals`). Needed to attribute regressions in section 12.

## 12. Performance budget

Measured (macOS 27, M-series, APFS) **[Exists]**:

| Tree | Command | Result |
|---|---|---|
| 1.46 M files (`~/work`) | Fil `--full` | ~7 s (7.15 / 7.11 / 7.13 s with clone attributes; 6.86 / 6.93 / 6.90 s before them, +3%) |
| 1.46 M files | `du` | ~40 s |
| 1.46 M files | `FileManager` (naive) | ~42 s |
| `/`, 6.85 M files | `fil scan / --full -j 8` | 56 s |
| 1.5 M files | with `ATTR_CMNEXT_PRIVATESIZE` (`--private`) | +70% |

Budget **[New]**, checked by `scan-tester` before any engine change is merged:

| Item | Budget |
|---|---|
| `~/work`-class tree, 1.46 M files, `--full -j 8`, median of 3 interleaved runs | <= 7.5 s; > 5% over the previous median needs a stated reason |
| `fil scan / --full -j 8` | <= 60 s |
| Throughput floor | >= 190k files/s on a warm cache tree of >= 1 M files |
| Per-file cost | no syscall, lock or heap allocation per file, except per multiply-linked file (one registry claim, batched per directory after #18) and `vet` during updates |
| Per-directory cost | one `open`, one `close`, `getattrlistbulk` calls, one `cond` round-trip, <= 1 `CloneRegistry` lock, <= 1 `HardlinkRegistry` lock (after #18); plus one `fstat` for incremental reads (#4) |
| Memory | 96 bytes per directory (104 after #49) + names > 15 bytes + registries; 256 KB buffer per worker |
| `--private` | allowed to exceed the budget (opt-in) |

## 13. Tests

**[Exists]** `Tests/ScanCoreTests/ScanCoreTests.swift`: sizes match `du -skx`; hard links counted once; an
unreadable folder is counted in `openErrors` and left empty; symlinks not followed; snapshot round trip and
corrupt-snapshot rejection. `scripts/verify.sh`: incremental vs full scan vs `du -skx` on fresh fixtures.

**[Change] (#20)** Missing, to add: `SF_DATALESS` files and directories; device crossing (`mountsSkipped`) and
Mount/Unmount (with #4); invalid UTF-8 names (with #6); `getattrlistbulk` errors and partial reads (with #7);
concurrent access to the hard-link and clone registries (many threads claiming the same inodes and families:
totals equal a single-thread scan); `-j 0` rejected (section 4.3); a directory removed during a full scan
(section 9.1). Update-side gaps (`historyUntrusted`, `historyTimeout`, `barrierTimeout`, `volumeChanged`,
`rootUnreadable`, snapshot rejection on `privateSize` or version, non-ASCII and case-only renames) belong to chapter 03.

## As built

- #44 (2026-10-19): `Scanner.scan` prints `[timing] scan.walk`, `scan.originals` and `scan.totals` with
  `FIL_TIMINGS=1` (`walk` includes `compact()`). With timings off the `Lap` is never created, so no clock is read;
  laps surround phases only. `--timings` (list/clean) is the CLI's own phase report and independent of
  `FIL_TIMINGS`; chapter 05 does not link them, so they stay separate (a reading). Test:
  `SnapshotCLITests.fullScanPrintsEngineLapsWithFILTimings`.
- #43 (2026-10-19): `scripts/bench.sh` builds a deterministic fixture of 1,000,000 file names under
  `/private/tmp/fil-bench.*` (37 s with `mkdir -p`/`touch`/`cp`/`ln` batched by `xargs`): 40% in wide folders (2,000
  files each), 30% in 16-deep chains, 30% in a three-level tree; one file in eight holds 1-8 KB; 5,000 plain 1-64 KB
  files, 3,000 `cp -c` clones, 2,000 files with two extra hard links each, four sparse files (2-16 GB). It counts
  996,000 files (4,000 names are extra links) and 21,018 folders. It runs `--full -j 8 --top 0 --porcelain` 3x
  interleaved with `du -skx` (alloc must equal du x 1024), then 3 rounds of 1,000 changes (300 deletes, 300 appends,
  400 adds), each followed by an incremental update (must report `mode=incremental` and equal `--full`). Options
  `--files N`, `--keep`, `--reuse DIR`, `--fil PATH`. Baseline: `main` at 7571e5a plus this script, release build,
  Mac15,10 (14 cores, 36 GB), macOS 27.0 (26A428). **The machine was not quiet**: other agents ran simulators and
  builds, the 1-minute load average was 9-15 during the runs (above the limit of 4; 11 minutes of waiting never
  brought it below), so read the times as pessimistic. The two complete runs agree within 3%.

  | Metric | Fresh fixture | Reused fixture |
  |---|---|---|
  | Full scan, median of 3 | 1.86 s (1.86 / 1.87 / 1.81) | 1.88 s (1.90 / 1.88 / 1.88) |
  | Files per second | 535k | 530k |
  | Incremental update after 1,000 changes, median of 3 | 0.42 s (0.71 / 0.42 / 0.34) | 0.32 s (0.47 / 0.32 / 0.28) |
  | Peak RSS (full) | 15 MB | 15 MB |
  | Snapshot | 1,007,507 bytes | 1,007,507 bytes |
  | alloc = du x 1024; incremental = `--full` | all equal | all equal |

  Against section 12: 1.46 M files `--full -j 8` <= 7.5 s: within (1.9 s for 0.996 M files, about 2.8 s scaled; the
  fixture is mostly empty files, so a real tree such as `~/work` stays the better check); throughput >= 190k files/s:
  within (530k); memory (96 bytes per folder + 256 KB per worker): within (15 MB, 21k folders); `fil scan / --full`
  <= 60 s: not measured (the harness stays inside its fixture); per-file and per-directory costs and `--private`: not
  measurable from outside (code review or `FIL_TIMINGS`). The incremental figure has no budget line. Elapsed time
  includes process start and snapshot load and save.
- #48 (2026-10-18): the request carries `ATTR_DIR_ALLOCSIZE` and `ATTR_DIR_DATALENGTH` (after `MOUNTSTATUS` in bit
  order). `DirOutcome.childAllocs` holds the non-zero folder allocations by child index (empty on APFS and HFS+: no
  allocation); `WorkItem.selfAlloc` carries one to the child's read, `DirOutcome.selfAlloc` is the `fstat`
  `st_blocks` x 512 of a scan root, a rescan root or a directory an update re-reads (the device check makes that
  `fstat` already). `DirReader.Config.allocUnit` is `statfs.f_bsize`, read once per scan or update. Details and the
  file systems checked: chapter 02 As built.

- #4 (2026-10-18): two facts the chapter did not know. (1) `getattrlistbulk` returns, for a mount point, the
  `ATTR_CMN_DEVID` of the covered directory, so the §8 check never skipped mount points and even `--full` entered
  them. Listings now flag mount points (mount-status attribute) and take their device from one `lstat` each, as
  `du -x` does; `fil scan / --full` no longer enters `/dev`, `/System/Volumes/VM`, `Preboot`, `/Volumes/*`, autofs,
  NFS or cryptex mounts, so its total drops (correctly) and `mountsSkipped` rises. (2) FSEvents history never holds
  Mount/Unmount events. `checkOwnDevice`/`EXDEV` is built as specified; each update also reads the mount table once
  (`getfsstat`) and rescans tree folders that became mount points. "Unmount needs nothing more" is wrong: a folder
  uncovered by an unmount is not seen until its parent gets an event, and its contents are missing. Fixed with
  snapshot format 6 in #5 (skipped mount points recorded and compared with `getfsstat` on every update).
- #6 (2026-10-18): built as §3.1 (side table, byte paths), not with `openat` as the issue text says. Facts found:
  APFS refuses such a name (`EILSEQ`), HFS+ and FAT escape it on creation (`%FF`), exFAT refuses it, so no local
  volume lets a user make one. A FAT volume written elsewhere can hold a lone UTF-16 surrogate, which macOS lists as
  the bytes `ED A0 80`; but no path opens it (`du` fails too), so it stays an `open` failure. Names that are not
  UTF-8 *and* can be opened come from network volumes (SMB, NFS). `DirOutcome.rawChildDirs` carries the bytes;
  `DiskTree.cPath(of:)` is optional (nil: `path(of:)` is exact, the usual case). Snapshot: section tag
  `0x8000_0006` (must-understand), written only when `rawNames` is not empty, so other format-6 files are unchanged.
  Updates match children by display name; `HardlinkRegistry.vet` and mount-point names still use display paths
  (a raw name there is only missed, never miscounted). Tests: a real listing from a patched FAT image, and a folder
  whose display name differs from its bytes (re-read, rescan and snapshot by bytes).
- #7 (2026-10-18): built as §3.3. `ATTR_CMN_ERROR` is in a record only when that entry failed (its bit is set in
  `RETURNED_ATTRS` then; otherwise the field is absent), as the parser already assumed. Readings: an update re-read
  sets `incomplete` from its outcome and clears it when the folder turns unreadable; the warning header becomes
  `<n> folder(s) could not be read fully; sizes below it are / them are too low.` when any listed folder is
  incomplete (otherwise unchanged), incomplete folders come last with `  (could not be read completely)` and no
  `stat`. Fault hook: `DirFaults` in `ScanOptions`/`DirReader.Config`, compiled only under `DEBUG` (no release cost):
  per path, errno values for successive `getattrlistbulk` calls (0 = real call) and an error record replacing the
  first entry; the debug `fil` binary reads them from `FIL_TEST_FAULTS` for CLI tests.
- #34 (2026-10-18): built as §9.1. Reading: the rule also covers directories below the root of an update's rescan
  (`rescanSubtrees` is shared); the root of a rescan or re-read keeps its old handling (removed by the caller).
  `Scanner.scan` compacts the tree after the walk, so a fresh tree holds no dead node. Fault: `removeBeforeOpen`
  (`remove <path>` in `FIL_TEST_FAULTS`) deletes the folder right before its `open`.
- Review fixes (2026-10-18): (1) `ENOENT` does not prove a raw-named folder gone (a FAT name with a lone surrogate
  lists but never opens): such a folder stays `unreadable` in a full scan, an update re-read and a rescan. A child
  gone because its parent's own path is gone (parent renamed or removed mid-walk; one `lstat` per gone child) marks
  the parent `incomplete`; a child deleted on its own does not. Fault `renameBeforeOpen`. (2) The update diff keys
  children by their bytes (`rawNames` bytes, else UTF-8 of the name), so names whose display forms collide stay
  apart and a rename between two raw names is a removal plus an addition. (3) An incomplete re-read keeps known
  children it did not list (the listing proves nothing about them); only new names are added.
- Second review (2026-10-18): (1) on an incomplete re-read each unlisted known child gets one `lstat` (by bytes for a
  raw name) and is kept only while it is a directory on the tree's volume; a rename seen only as the parent's event
  is no longer counted twice. Reading: `DirNode` stores no inode, so a folder deleted and recreated under the same
  name in between is kept with its old sizes until its next read (#49 adds the identity: §5.1, chapter 03
  §5.2). (2) Every update re-reads each live `incomplete` folder, also with no events (one pass over the node
  flags per update); a flagged folder whose own path is gone has its parent read too. (3) Names identify children by UTF-8 bytes: `ChildKey` compares bytes, and
  `DiskTree.child(of:named:)` prefers a byte-equal name and falls back to a canonically equal one, so events and
  typed paths in another normalization still find their folder.

## Glossary additions

- `DirNode`: one directory record in `DiskTree.nodes`; dead node: `parent == DirNode.dead` (-2).
- `DirReader`, `DirReader.Config` (`rootDev`, `options`, `userAccess`, `exclusions`), `DirReader.bufSize`.
- `DirOutcome` and its fields (`childDirs`, `deniedChildDirs`, `deferredLinks`, `cloneMembers`, `opened`,
  `openError`, `isGone`).
- `ParallelScan`, `WorkItem`, local id / `globalId`.
- `ScanOptions` (`threads`, `privateSize`, `crossDevices`, `strictHardlinks`, `firmlinks`).
- `ScanStats` and its eight fields; `ScanProgress`.
- `ChildLinks` (`first`, `next`), `syncLinks`, `compact`, remap.
- Owner / others (registry entry roles); orphan (entry with `owner == -1`).
- Unattributed hard link; `birthCutoff`; drift (size change seen through a non-owning link); `uncertainBytes`
  (porcelain `uncertain=`); strict / tolerant hard links.
- Denied (`openErrors`); entry error (`entryErrors`); gone (`isGone`).
- Incomplete directory (**[New]**, #7).
- `DirNode.fileID`, folder identity (**[New]**, #49); allocation unit (**[New]**, #48, chapter 02).
- `rawNames` (**[New]**, #6); `DirReader.Config.checkOwnDevice` (**[New]**, #4, shared with chapter 03).
- Naive mode (`--naive`); `FIL_TIMINGS`; `FIL_SNAPSHOT_DIR`.
- Full scan (`--full`).
