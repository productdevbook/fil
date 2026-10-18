# 02 Size accounting

How `fil scan` counts bytes so that every allocated block is counted once: the size fields (`alloc`,
`cloneaware`, `shared`, private mode), the boot volume group and firmlinks, and APFS clones. This chapter
supersedes `docs/specs/accounting.md`; every rule and measurement of that spec is kept here.

Sources: `Sources/ScanCore/Firmlinks.swift`, `Sources/ScanCore/Clones.swift`, `DirReader` in
`Sources/ScanCore/Scanner.swift`, `HardlinkRegistry` in `Sources/ScanCore/DiskTree.swift`, the update side in
`Sources/ScanCore/Incremental.swift`, the format in `Sources/ScanCore/Snapshot.swift`, the output in
`Sources/fil/Scan.swift`. The directory reader, attribute layout and hard-link registry are specified in
[01 Scan engine](01-scan-engine.md).

Status tags: **[Exists]** is in the code today (file reference given); **[Change]** is in the code and changes
as described here (reason and issue given); **[New]** does not exist yet.

## 1. Size fields

### 1.1 Per file

**[Exists]** (`DirReader.parseEntry`, `Scanner.swift:321`). Two allocated sizes are read per file:

- `realAlloc` = `ATTR_FILE_ALLOCSIZE`.
- `alloc` = `ATTR_FILE_ALLOCSIZE`, or `ATTR_CMNEXT_PRIVATESIZE` with `--private` (`ScanOptions.privateSize`).

| File kind | `alloc` / `logical` / `files` | `cloneAware` |
|---|---|---|
| `SF_DATALESS` | 0 / 0 / +1 (`datalessLogical += DATALENGTH`) | 0 |
| hard-linked `VREG`, owning link | `alloc` / `DATALENGTH` / +1 | `realAlloc` |
| hard-linked `VREG`, other link | nothing (`hardlinkDupes += 1`) | nothing |
| full clone (`EF_SHARES_ALL_BLOCKS`, `cloneID != 0`, `VREG`, 1 link) | `alloc` / `DATALENGTH` / +1 | family's `alloc` once per family, in the owning directory (section 4) |
| anything else (incl. partial clones, symlinks) | `alloc` / `DATALENGTH` / +1 | `realAlloc` |

### 1.2 Tree fields and output

**[Exists]** (`Scan.swift:105-131`). `r` is the root `DirNode`.

| Porcelain field | Formula | Meaning |
|---|---|---|
| `mode=` | `incremental` or `full` | how the tree was obtained |
| `alloc=` | `r.totalAlloc` | Sum of `ATTR_FILE_ALLOCSIZE` with hard links counted once: what `du -skx` reports (x 1024). Unchanged by clone accounting. With `--private` it is the sum of `ATTR_CMNEXT_PRIVATESIZE`, as before. |
| `logical=` | `r.totalLogical` | Sum of data lengths (dataless files excluded). |
| `files=` | `r.totalFiles` | Files counted (dataless included, extra hard links excluded). |
| `dirs=` | `r.totalDirs + 1` | Directories including the root. |
| `uncertain=` | `DiskTree.uncertainBytes` | Only with `--tolerant-hardlinks` (chapter 01, 6.3). |
| `cloneaware=` | `r.totalCloneAware` | Real usage: like `alloc`, but each APFS full-clone family counted once. Always from `ATTR_FILE_ALLOCSIZE`, also with `--private`. Shown as "on disk" and used to rank the tree. |
| `shared=` | `r.totalAlloc - r.totalCloneAware` | Bytes `du` counts again for every extra clone. Not printed with `--private`. |
| `unreadable=` | live nodes with `unreadable` | Folders that could not be read. |

Field order on the line is exactly the order of this table; `uncertain=` and `shared=` are present or absent
depending on flags, so parsers must key on field names, not positions. Porcelain fields are only ever appended
(new ones go after `unreadable=`), so existing parsers keep working.

Human output: the headline is `cloneaware` with the label `on disk`, or `alloc` with the label `private` under
`--private`; directories are ranked by the same size. When `shared > 0` a line reads
`<shared> shared by clones, counted once (du without clone dedupe: <alloc>)`.

### 1.3 Identities

**[Exists]**, must hold for every tree (tested in `AccountingTests.swift`):

- Without `--private`: `0 <= cloneaware <= alloc`, so `shared >= 0`.
- `alloc` (without `--private`) `== du -skx x 1024` under the conditions of chapter 01, invariant 8.
- With `--private`, `alloc` holds private bytes and `cloneaware` still holds clone-aware `ATTR_FILE_ALLOCSIZE`
  bytes; no ordering between them is guaranteed, which is why `shared` is not printed.
- A hard-linked file contributes the same `realAlloc` to `cloneaware` as it would without clones: hard-link rules
  take precedence over clone rules (rule 4 below).

## 2. Volume group and firmlinks

### 2.1 Problem

**[Exists]** On macOS the boot volume is a group: a sealed system volume mounted at `/` and a data volume mounted
at `/System/Volumes/Data` (the **data root**). Both report the same `st_dev`, so the "never cross devices" rule
does not separate them. Firmlinks (listed in `/usr/share/firmlinks`, e.g. `/Users` -> `Users`) make data-volume
directories appear on the system volume; the same directory (same inode) is reachable as `/Users/code` and as
`/System/Volumes/Data/Users/code`. A scan of `/` used to walk both and count the data volume twice.

### 2.2 Rule

**[Exists]** When a scan covers both a firmlink's source and its data-volume directory, it descends only through
the firmlink. Formally, for root `R` and each firmlink `(source, target)`, the directory `dataRoot/target` is not
entered when `source` is `R` or inside `R`, and `dataRoot/target` is strictly inside `R`
(`FirmlinkTable.aliases(for:)`, `Firmlinks.swift:73`). Each such skipped directory is an **alias**.

Consequences:

- Paths stay user-friendly: `/Users/code`, `/private/var/...`, `/Applications`.
- `/System/Volumes/Data` still shows what is only reachable there (`.Spotlight-V100`, `MobileSoftwareUpdate`,
  `mnt`, `sw`, data parts of `/System` and `/usr` that are not firmlinked, ...), so nothing is lost.
- A scan of a subtree that does not contain a firmlink source (`~/work`, `/Users`, `/System/Volumes/Data`) skips
  nothing and still matches `du -skx`.
- The table is read from `/usr/share/firmlinks` (only when `/System/Volumes/Data` is a mount point), never
  hardcoded; tests inject their own (`ScanOptions.firmlinks`).
- The skipped directories (aliases) are stored in the snapshot. FSEvents may report changes under the data
  volume path; the update rewrites them to the firmlink path. If the system's table no longer gives the same
  aliases, the update fails with `firmlinksChanged` and a full scan runs.
- A scan of `/` with aliases does **not** equal `du -skx /` (which walks both views); it equals `du` minus the
  aliased directories.

Other APFS volumes of the container (`/System/Volumes/Preboot`, `VM`, `Update`, `xarts`, `iSCPreboot`,
`Hardware`, `/Volumes/*`, cryptex mounts) have their own device and are not entered. `fil scan /` therefore
covers exactly the system and data volumes; its total is comparable to `df` "used" of `/` plus
`/System/Volumes/Data`, minus what the user cannot read (TCC-protected and root-only directories, counted in
"denied"), minus APFS metadata and snapshots.

### 2.3 `FirmlinkTable`

**[Exists]** (`Firmlinks.swift`)

| Type / member | Definition |
|---|---|
| `FirmlinkTable.Link` | `source`: absolute path on the system volume (`"/Users"`); `target`: path relative to the data root (`"Users"`). |
| `FirmlinkTable.Alias` | `dataPath`: where the data volume shows it, not descended into (`"/System/Volumes/Data/Users"`); `source`: the firmlink it is scanned through (`"/Users"`). `Equatable`. |
| `dataRoot` | Mount point of the data volume, `""` when there is no volume group. |
| `FirmlinkTable.empty` | `dataRoot: ""`, no links: `aliases(for:)` is always empty. |
| `FirmlinkTable.system` | `load()` of the running system, evaluated once per process. |
| `load(file: "/usr/share/firmlinks", dataRoot: "/System/Volumes/Data")` | `statfs(dataRoot)`; empty unless it succeeds **and** `f_mntonname == dataRoot`, and the file reads as UTF-8; then `parse`. |
| `parse(_ text:, dataRoot:)` | One link per line: absolute source, tab(s), target. Lines split on newlines; fields split on `"\t"` with empty fields dropped; exactly 2 fields required. Source: trailing slashes trimmed (`normalize`), must start with `/` and not be `/`. Target: leading and trailing `/` trimmed, must be non-empty. Invalid lines are skipped silently. `dataRoot` normalized. |
| `aliases(for root:)` | Empty if `dataRoot` is empty. Otherwise, for each link, `dataPath = dataRoot + "/" + target`; kept when `isInside(source, root, orEqual: true)` and `isInside(dataPath, root, orEqual: false)`. Sorted by `dataPath`. `root` normalized. |
| `isInside(path, root, orEqual:)` | `path == root` returns `orEqual`; otherwise true when `root == "/"` or `path` has prefix `root + "/"`. |
| `normalize(p)` | Drops trailing `/` while longer than 1 character. |

Examples, with the system table:

| Root | Aliases |
|---|---|
| `/` | every firmlink, e.g. `/System/Volumes/Data/Users` (via `/Users`), `/System/Volumes/Data/Applications`, `/System/Volumes/Data/private/var` ... |
| `/System` | those whose source is under `/System` and whose data path is under `/System`; `/System/Volumes/Data` itself is never an alias |
| `/Users`, `~`, `~/work`, `/System/Volumes/Data` | none |

### 2.4 Exclusions and event paths

**[Exists]**

- `[FirmlinkTable.Alias].exclusions` (`Firmlinks.swift:98`): `parentPath -> Set<childName>` built by splitting
  each `dataPath` at its last `/` (parent `/` when the slash is first). `DiskTree` stores it as `exclusions`;
  `DirReader` looks up `exclusions[path]` once per directory and skips a child directory whose name is in the set
  (`firmlinksSkipped += 1`). Cost when there are no aliases: one `isEmpty` check per directory.
- `translate(_ path:)` (`Firmlinks.swift:109`): the first alias whose `dataPath` is a prefix of `path`, with the
  remainder empty or starting with `/`, rewrites it to `source + remainder`; otherwise unchanged.
- `Incremental.rootPrefixes(root)` (`Incremental.swift:416`): the prefixes under which an event belongs to the
  tree: `root`, `realpath(root)`, and the data-volume twin `"/System/Volumes/Data" + root` (just
  `/System/Volumes/Data` for `/`) only when that twin is not inside the tree itself (for `/` or `/System` it is
  a real directory of the tree, whose events keep their own path). `/` is stored as `""`.
- `Incremental.relativeComponents(path, prefixes:, aliases:)`: trims trailing `/`, applies `translate` when there
  are aliases, then returns the components below the first matching prefix (`[]` for the root, nil when
  outside).
- `Incremental.update` compares `options.firmlinks.aliases(for: tree.rootPath)` with `tree.aliases` before
  replaying; any difference: `UpdateFailure.firmlinksChanged`.

## 3. APFS clones

### 3.1 Problem and attributes

**[Exists]** `cp -c`, Finder copies and many apps (Chrome's code-sign clones, Xcode, simulators) create clones
that share blocks. `ATTR_FILE_ALLOCSIZE` reports every clone's full size, so `du` (and `alloc`) can exceed the
disk.

Attributes read in the same `getattrlistbulk` call, per file (requires `FSOPT_ATTR_CMN_EXTENDED`):

- `ATTR_CMNEXT_EXT_FLAGS`: `EF_SHARES_ALL_BLOCKS` (0x40; full clone: every block shared with another file) and
  `EF_MAY_SHARE_BLOCKS` (0x1; may share some blocks).
- `ATTR_CMNEXT_CLONEID`: identifies the data stream; all full clones of one file have the same id, and the
  original's file id equals it.

Both are inode fields. `ATTR_CMNEXT_PRIVATESIZE` (bytes freed if the file were deleted) walks the extents and made
a full scan of a 1.5 M-file tree 70% slower, so it is not requested by default (only with `--private`).
`ATTR_CMNEXT_CLONE_REFCNT` is not needed.

### 3.2 Rules for the clone-aware size

**[Exists]**

1. A file without `EF_SHARES_ALL_BLOCKS`: its allocated size (same as `alloc`).
2. A full clone (`EF_SHARES_ALL_BLOCKS`, single link): its family (clone id) is counted once, with the member's
   allocated size, in the directory that owns the family (`CloneRegistry`, the same model as `HardlinkRegistry`).
   The directory holding the original (file id == clone id) is preferred as owner, so the attribution does not
   depend on the order workers read directories; without the original in the tree the first claimant owns it.
   An original that has been cloned is itself a full clone and a member of its family.
3. A partial clone (`EF_MAY_SHARE_BLOCKS` without `EF_SHARES_ALL_BLOCKS`, e.g. a clone modified after copying):
   counted in full. Which file it shares blocks with cannot be learned from bulk attributes, so this is the
   conservative choice: it never under-reports, and over-reports by at most the shared part. Measured: 51 MB
   over 2,363 partial clones in a 105 GB tree.
4. A hard-linked file (link count > 1) is counted once by the hard-link rules with its full size and is not
   deduplicated as a clone (rare; documented limitation).

The dedupe costs one registry lock per directory that contains full clones, not per file.

All members of a family are assumed to have the same `ATTR_FILE_ALLOCSIZE`; the family's counted size is the
`alloc` of the member that created or last re-claimed the entry.

### 3.3 `CloneMember` and `CloneRegistry`

**[Exists]** (`Clones.swift`)

`CloneMember`: `cloneID: UInt64`, `alloc: Int64` (always `realAlloc`), `isOriginal: Bool` (`cloneID == fileID`).
Collected per directory in `DirOutcome.cloneMembers`.

`CloneRegistry`: `[UInt64: Entry]` keyed by clone id, under one `NSLock`.

| `Entry` field | Meaning |
|---|---|
| `owner: Int32` | Directory whose `ownCloneAware` includes the family; -1 while released and not re-claimed. |
| `original: Int32` | Directory holding the original file; -1 if not seen. |
| `alloc: Int64` | Size counted for the family. |
| `others: [Int32]` | Other directories where a member was seen; never contains `owner`; may repeat a directory for families with more than 64 entries. |

Operations:

| Method | Behaviour |
|---|---|
| `claim(_ members:, by dir:) -> (bytes, dupes)` | One lock for the whole directory. Per member: unknown id: new entry, `owner = dir`, `original = isOriginal ? dir : -1`, counts `alloc`; during an update a non-original creation is recorded in `created`. Known id: if `isOriginal`, `original = dir`. Owner is `dir`: nothing (a second member here). Owner released: `dir` becomes owner, `alloc` replaced, `dir` removed from `others`, counts. Other owner: append `dir` to `others` unless it is already the last element, or (only while `others.count <= 64`) anywhere in it. Returns bytes now owned by `dir` and `members.count - owned`, which the caller adds to `cloneDupes`. |
| `preferOriginals() -> [(from, to, alloc)]` | For each entry with `original >= 0`, `owner >= 0`, `owner != original`: owner becomes `original`, old owner goes to `others`. The caller (`Scanner.applyPreferredOriginals`) moves `alloc` from `ownCloneAware[from]` to `ownCloneAware[to]`. Runs after every full scan and every update, before totals. |
| `forget(where:)` | Releases owner (-1) and `original` (-1) when their directory matches; removes matching `others`; deletes entries with no owner and no `others`; sets `hasOrphans` otherwise. |
| `resolveOrphans() -> [(dir, alloc)]` | Each released entry goes to `original` if it is in `others`, else `others.first`; removed from `others`. No candidate: entry deleted. The caller adds `alloc` to the new owner's `ownCloneAware`. |
| `beginUpdate()` / `takeCreated()` | Start / stop recording families created by a non-original member during an update. |
| `adopt(_ cloneID:, by dir:) -> (previous, alloc)?` | Sets `original = dir`; if `dir` is not already owner, makes it owner, moves the previous owner (if any) to `others`, returns it so the caller subtracts `alloc` from its `ownCloneAware`. |
| `entry(_:)` | Locked read of one entry. |
| `remap(_ map:)` | After `DiskTree.compact`: renumber `owner`, `original`, `others`; drop entries whose owner is gone. |

### 3.4 Incremental updates

**[Exists]** Incremental updates keep the clone-aware size exact:

- Re-read directories drop and re-claim their members after `forget` (claims are queued as `pendingClones` and
  made after `forget`, like hard links).
- An orphaned family moves to another directory that still holds a member (the original's first)
  (`resolveOrphans`).
- A family that is new to the tree although its original was already there (the original was cloned after the
  snapshot and its directory, not re-read, counts it as a plain file) is handed to the original's directory
  (`Incremental.adoptOriginals`). The original is found with `fsgetpath(fsid, cloneID)` and checked with one
  `getattrlist` (`isSingleLinkClone`: `VREG`, link count 1, file id == clone id, `CLONEID` == clone id,
  `EF_SHARES_ALL_BLOCKS`): two syscalls per such family, only in updates. Conditions for adoption: the entry has
  `original < 0` and `owner >= 0`; the path maps into the tree (aliases applied); its directory is live, not
  `unreadable`, existed before this update and was not re-read by it. The previous owner stops counting the
  family; the original's directory already counts the file through rule 1.
- `preferOriginals` runs again at the end of each update.

**[Change] (#16)** `forget`, `resolveOrphans` and `remap` iterate the whole table. Same fix as the
`HardlinkRegistry` (chapter 01, 6.4): a `byDir: [Int32: [UInt64]]` index of the families where a directory is
owner, original or in `others`, so `forget` touches only the affected directories, and an orphan list so
`resolveOrphans` touches only released entries. `preferOriginals` after an update visits only families touched
by this update (collected during `claim`, `forget`, `resolveOrphans` and `adopt`).

**[Change] (#18, consistency)** Clone claims are already batched per directory; no change. Hard-link claims move
to the same per-directory batch (chapter 01, 4.4).

### 3.5 Snapshot

**[Exists]** Snapshot format 5 stores `ownCloneAware` per directory, the clone-family table and the firmlink
aliases (`Snapshot.swift`):

- Header: `magic u32 (0x4D545A31, "MTZ1") | version u32 (5) | privateSize u8 | rootDev i32 | eventId u64 |
  scanStart i64 | uncertainBytes i64 | volumeUUID | rootPath | aliases | nodes | hard links | clone families`.
- Aliases: `u32 count`, then per alias `dataPath`, `source` (strings).
- Node: `parent i32 | flags u8 (bit 0 unreadable) | ownAlloc i64 | ownLogical i64 | ownFiles i64 |
  ownCloneAware i64 | name`. Totals are not stored; `computeTotals` runs on load.
- Hard-link entry: `inode u64 | owner i32 | alloc i64 | logical i64 | cloneAware i64 | u32 count | others i32...`.
- Clone family: `cloneID u64 | owner i32 | original i32 | alloc i64 | u32 count | others i32...`.
- Older versions are not read: a full scan rebuilds what they lack. A snapshot of the other `privateSize` mode or
  another root path is not used.

**[Change] (#5, #6, #7, #15)** Format 6 (layout owned by chapter 03, section 6): mode byte (bit 0 `privateSize`,
bit 1 `crossDevices`), the last full scan's `ScanStats` and `fullScanStart`; plus, from chapter 01, node flags
bit 1 `incomplete` (#7) and a `rawNames` table after the clone families (`u32 count`, then `id i32 | u32 length |
bytes`) (#6). Version 5 files are rejected (full scan), as for every bump.

## 4. Who owns what: summary

| Thing | Registry | Key | Owner choice in a full scan | Preferred owner |
|---|---|---|---|---|
| Hard-linked inode | `HardlinkRegistry` | file id | first directory to claim (worker order) | none |
| Clone family | `CloneRegistry` | clone id | first directory to claim, then moved by `preferOriginals` | directory of the original |
| Firmlinked directory | `FirmlinkTable.aliases(for:)` | path | always the firmlink source path | — |

## 5. Measurements (macOS 27, M-series, 2026-10-18)

**[Exists]**

- `fil scan / --full -j 8`: before 2.4 TB, 13.0 M files, 1m48s; after 578.1 GB on disk (alloc 1.2 TB,
  621.0 GB shared by clones), 6.85 M files, 56 s. `df`: `/` 13.7 GB + Data 690.6 GB = 704.3 GB used; the rest is
  in 795 directories the user cannot read (`~/Pictures`, `~/.Trash`, `~/Library` containers, `/private/var/db`,
  Spotlight) and APFS metadata.
- Chrome `code_sign_clone` folder: 581.8 GB before; 1.5 GB scanned alone; 0 B inside a scan of `/`, where its
  families belong to `/Applications/Google Chrome.app`.
- `~/work` (1.46 M files) `--full`, 3 runs interleaved: before 6.86/6.93/6.90 s, after 7.15/7.11/7.13 s (+3%);
  alloc still equals `du -skx` x 1024.
- Partial clones: 51 MB over-reported over 2,363 partial clones in a 105 GB tree.
- `ATTR_CMNEXT_PRIVATESIZE`: a full scan of a 1.5 M-file tree 70% slower.

## 6. Tests

**[Exists]** `Tests/ScanCoreTests/AccountingTests.swift`: a full-clone family counted once with `alloc` still
equal to `du`; clones without the original; a modified (partial) clone counted in full; a hard-linked clone
counted once as a hard link; `--private` keeps private bytes in `alloc` and still reports clone-aware size; clone
families survive a snapshot round trip and updates; original adoption, including not adopting into an
unreadable directory; ownership moving to the original and back; a re-read directory reclaiming its own family;
firmlink table parsing; alias selection; data-volume event translation; `/` and `/System` prefixes; a scan with
an injected table counting a firmlinked directory once; `firmlinksChanged` on a different table; the system table
covering `/Users`.

**[Change] (#20)** Add: concurrent claims of one clone family from many directories in parallel (totals equal a
single-thread scan, family counted once); `shared` and `cloneaware` with a dataless file in a clone family.

## As built

## Glossary additions

- `realAlloc`: `ATTR_FILE_ALLOCSIZE` of a file, independent of `--private`.
- `logical` (porcelain `logical=`), `files=`, `dirs=`, `mode=`.
- Full clone (`EF_SHARES_ALL_BLOCKS`), partial clone (`EF_MAY_SHARE_BLOCKS` only), clone id, original
  (file id == clone id).
- `CloneMember`; `CloneRegistry.Entry` fields `owner`, `original`, `alloc`, `others`.
- `preferOriginals` / `applyPreferredOriginals`; adoption (`adopt`, `adoptOriginals`, `isSingleLinkClone`);
  `created` families.
- `cloneDupes`, `firmlinksSkipped` (also in chapter 01).
- Volume group; data volume; `FirmlinkTable`, `FirmlinkTable.Link` (`source`, `target`), `FirmlinkTable.Alias`
  (`dataPath`, `source`); exclusions; `translate`; `rootPrefixes`; `relativeComponents`.
- Snapshot format 5 (format 6 **[New]**).
