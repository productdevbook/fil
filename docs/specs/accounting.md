# Byte accounting: firmlinks and APFS clones

How `fil scan` counts bytes so that every allocated block is counted once. Engine: `Sources/ScanCore`
(`Firmlinks.swift`, `Clones.swift`, `DirReader` in `Scanner.swift`).

## Numbers

| Field (porcelain) | Meaning |
|---|---|
| `alloc=` | Sum of `ATTR_FILE_ALLOCSIZE` with hard links counted once: what `du -skx` reports. Unchanged. With `--private` it is the sum of `ATTR_CMNEXT_PRIVATESIZE`, as before. |
| `cloneaware=` | Real usage: like `alloc`, but each APFS full-clone family counted once. Always from `ATTR_FILE_ALLOCSIZE`, also with `--private`. Shown as "on disk" and used to rank the tree. |
| `shared=` | `alloc - cloneaware`: bytes `du` counts again for every extra clone. Not printed with `--private`. |

Porcelain fields are only ever appended (after `uncertain=` in tolerant mode), so existing parsers keep working.

## Volume group and firmlinks

On macOS the boot volume is a group: a sealed system volume mounted at `/` and a data volume mounted at
`/System/Volumes/Data`. Both report the same `st_dev`, so the "never cross devices" rule does not separate them.
Firmlinks (listed in `/usr/share/firmlinks`, e.g. `/Users` -> `Users`) make data-volume directories appear on
the system volume; the same directory (same inode) is reachable as `/Users/code` and as
`/System/Volumes/Data/Users/code`. A scan of `/` used to walk both and count the data volume twice.

Rule: when a scan covers both a firmlink's source and its data-volume directory, it descends only through the
firmlink. Formally, for root `R` and each firmlink `(source, target)`, the directory `dataRoot/target` is not
entered when `source` is `R` or inside `R`, and `dataRoot/target` is strictly inside `R`
(`FirmlinkTable.aliases(for:)`). Consequences:

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

Other APFS volumes of the container (`/System/Volumes/Preboot`, `VM`, `Update`, `xarts`, `iSCPreboot`,
`Hardware`, `/Volumes/*`, cryptex mounts) have their own device and are not entered. `fil scan /` therefore
covers exactly the system and data volumes; its total is comparable to `df` "used" of `/` plus
`/System/Volumes/Data`, minus what the user cannot read (TCC-protected and root-only directories, counted in
"denied"), minus APFS metadata and snapshots.

## APFS clones

`cp -c`, Finder copies and many apps (Chrome's code-sign clones, Xcode, simulators) create clones that share
blocks. `ATTR_FILE_ALLOCSIZE` reports every clone's full size, so `du` (and `alloc`) can exceed the disk.

Attributes read in the same `getattrlistbulk` call, per file (requires `FSOPT_ATTR_CMN_EXTENDED`):

- `ATTR_CMNEXT_EXT_FLAGS`: `EF_SHARES_ALL_BLOCKS` (full clone: every block shared with another file) and
  `EF_MAY_SHARE_BLOCKS` (may share some blocks).
- `ATTR_CMNEXT_CLONEID`: identifies the data stream; all full clones of one file have the same id, and the
  original's file id equals it.

Both are inode fields. `ATTR_CMNEXT_PRIVATESIZE` (bytes freed if the file were deleted) walks the extents and made
a full scan of a 1.5 M-file tree 70% slower, so it is not requested by default. `ATTR_CMNEXT_CLONE_REFCNT` is not
needed.

Rules for the clone-aware size:

1. A file without `EF_SHARES_ALL_BLOCKS`: its allocated size (same as `alloc`).
2. A full clone (`EF_SHARES_ALL_BLOCKS`, single link): its family (clone id) is counted once, with the member's
   allocated size, in the directory that owns the family (`CloneRegistry`, the same model as `HardlinkRegistry`).
   The directory holding the original (file id == clone id) is preferred as owner, so the attribution does not
   depend on the order workers read directories; without the original in the tree the first claimant owns it.
3. A partial clone (`EF_MAY_SHARE_BLOCKS` without `EF_SHARES_ALL_BLOCKS`, e.g. a clone modified after copying):
   counted in full. Which file it shares blocks with cannot be learned from bulk attributes, so this is the
   conservative choice: it never under-reports, and over-reports by at most the shared part. Measured: 51 MB
   over 2,363 partial clones in a 105 GB tree.
4. A hard-linked file (link count > 1) is counted once by the hard-link rules with its full size and is not
   deduplicated as a clone (rare; documented limitation).

The dedupe costs one registry lock per directory that contains full clones, not per file.

Incremental updates keep the clone-aware size exact: re-read directories drop and re-claim their members after
`forget`, an orphaned family moves to another directory that still holds a member (the original's first), and
a family that is new to the tree although its original was already there (the original was cloned after the
snapshot and its directory, not re-read, counts it as a plain file) is handed to the original's directory
(found with `fsgetpath` and checked with one `getattrlist`: two syscalls per such family, only in updates).
Snapshot format 5 stores `ownCloneAware` per directory, the clone-family table and the firmlink aliases.

## Measurements (macOS 27, M-series, 2026-10-18)

- `fil scan / --full -j 8`: before 2.4 TB, 13.0 M files, 1m48s; after 578.1 GB on disk (alloc 1.2 TB,
  621.0 GB shared by clones), 6.85 M files, 56 s. `df`: `/` 13.7 GB + Data 690.6 GB = 704.3 GB used; the rest is
  in 795 directories the user cannot read (`~/Pictures`, `~/.Trash`, `~/Library` containers, `/private/var/db`,
  Spotlight) and APFS metadata.
- Chrome `code_sign_clone` folder: 581.8 GB before; 1.5 GB scanned alone; 0 B inside a scan of `/`, where its
  families belong to `/Applications/Google Chrome.app`.
- `~/work` (1.46 M files) `--full`, 3 runs interleaved: before 6.86/6.93/6.90 s, after 7.15/7.11/7.13 s (+3%);
  alloc still equals `du -skx` x 1024.
