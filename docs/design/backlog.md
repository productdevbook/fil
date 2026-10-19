# Backlog

Every work item, numbered once, grouped by milestone ([08-roadmap.md](08-roadmap.md)). F-N is GitHub issue #N.
Items F-001…F-031 were filed before this design (from an audit); their text is rewritten here to the design.
New items start at F-032 and are numbered in build order. IDs are never reused; withdrawn items stay listed.

Owners: `designer`, `macos-engineer`, `release-engineer`, `scan-tester`, `owner` (the repository owner: GitHub
settings and secrets only a person with admin rights can change).

---

## M1 · Trustworthy numbers

### F-001 · Top-level error handling instead of a crash

- **Area** cli · **Owner** macos-engineer · **Priority** P0 · **Depends on** — · **Chapters** 05 §1, §7; 03 §7
- **Acceptance**
  - `fil scan /nonexistent/x` and `fil scan /nonexistent/x --porcelain` print `fil: /nonexistent/x: No such file
    or directory` on stderr and exit 1; no `Fatal error`, no exit 133.
  - An unreadable root (`lstat` fails) and a JSON encoding error each end in one `fil: <message>` line and exit 1.
  - A failing `Snapshot.save` is a warning (`fil: warning: could not save the snapshot (<reason>); the next run
    does a full scan`), normal output, exit 0 (chapter 05 §1.1).
  - `Tests/FilTests` runs the built binary for the cases above and checks stderr and exit status.

### F-011 · Resolve DIR; reject a missing path or a non-directory

- **Area** cli · **Owner** macos-engineer · **Priority** P0 · **Depends on** F-001 · **Chapters** 05 §3.1
- **Acceptance**
  - DIR is resolved with `realpath(3)`; `fil scan /tmp` scans `/private/tmp` and prints the resolved path.
  - `fil scan .` from two different folders uses two different snapshots (key is the resolved absolute path).
  - `fil scan <file>` prints `fil: <arg>: not a directory`, exit 1.
  - Tests for `/tmp`, `.`, a file and a missing path.

### F-004 · Mount and unmount events never add another volume's files

- **Area** scan · **Owner** macos-engineer · **Priority** P0 · **Depends on** — · **Chapters** 01 §8; 03 §4.6
- **Acceptance**
  - Mount/Unmount flags are lost-history flags (`historyUntrusted`), and re-read directories check their own
    device (`checkOwnDevice`, `EXDEV` → node removed), as in chapter 03.
  - Scenario: snapshot of a fixture, `hdiutil attach -mountpoint <fixture>/mnt <image>`, incremental scan: files
    and `alloc` equal `fil scan <fixture> --full` and `du -skx`. Same after `hdiutil detach`.
  - The scenario is an automated test and a `scripts/verify.sh` case.

### F-032 · A strict scan never uses a snapshot with uncertain bytes

- **Area** scan · **Owner** macos-engineer · **Priority** P0 · **Depends on** — · **Chapters** 03 §8.3
- **Acceptance**
  - After `fil list` leaves `uncertainBytes > 0` in the home snapshot, `fil scan ~` runs a full scan; `-v` shows
    `full scan (snapshot has uncertain bytes)`.
  - A full scan resets `uncertainBytes` to 0.
  - Test with a fixture that produces an unattributed hard link in tolerant mode.

### F-005 · Snapshot records the device-crossing mode

- **Area** scan · **Owner** macos-engineer · **Priority** P1 · **Depends on** — · **Chapters** 03 §6.4, §6.5
- **Acceptance**
  - Snapshot format 6: mode byte bit 1 = cross devices; version 5 files are rejected (full scan, no crash).
  - Loading with the other mode is rejected; test for both directions.
  - The snapshot records the mount points the scan skipped inside the root; every update compares them with
    `getfsstat` and re-reads the parent of any that is gone (finishes #4: after `hdiutil detach`, a non-empty
    folder that was covered is counted). The `mountAndUnmount` test becomes a hard check with a non-empty folder,
    and the `mount: detached` case in `scripts/verify.sh` passes.

### F-033 · One snapshot per root and mode

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** F-005, F-011 · **Chapters** 03 §6.1
- **Acceptance**
  - The snapshot file name is derived from the resolved root path and the mode byte, so `fil scan X` and
    `fil scan X --private` keep separate snapshots.
  - Alternating the two runs is incremental each time after the first pair (shown in `-v`).
  - Chapter 03 §6.1 is updated with the naming rule before the code ("As built" if it differs).

### F-006 · Directories with invalid UTF-8 names are scanned

- **Area** scan · **Owner** macos-engineer · **Priority** P1 · **Depends on** — · **Chapters** 01 §3.1, §3.4
- **Acceptance**
  - Children are opened by raw name relative to the parent (`openat`), as in chapter 01.
  - Fixture with a directory named with byte `0xFF` holding 10 MB: `fil scan --full` `alloc` equals `du -skx`,
    `unreadable=0`.
  - Hot-path budget unchanged (chapter 01 §12).

### F-007 · Partial directory reads are marked incomplete

- **Area** scan · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-005 · **Chapters** 01 §3.3, §5.1, §9.1
- **Acceptance**
  - `EINTR` is retried; a `getattrlistbulk` failure mid-directory or a per-entry `ATTR_CMN_ERROR` sets
    `DirNode.incomplete`, stored in the snapshot flags byte.
  - Incomplete directories are counted in `unreadable=` and listed with the unreadable folders.
  - A test-only fault hook in `DirReader` produces one incomplete directory; output and porcelain checked.

### F-034 · A folder that disappears during a scan is not reported as unreadable

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 01 §9.1
- **Acceptance**
  - A directory whose `open` fails with `ENOENT`, `ENOTDIR` or `ELOOP` during a full scan (`isGone`) is dropped, not
    counted in `unreadable=` or the permission warning.
  - Chapter 01 §9.1 is updated first.
  - Test: a directory removed between listing and opening (fault hook) does not appear as unreadable.

### F-015 · Scan stats survive snapshots; `DiskTree.nodes` is read-only outside the engine

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** F-005 · **Chapters** 01 §9.2, §5.6; 03 §6.5, §9
- **Acceptance**
  - Format 6 stores `ScanStats` and `fullScanStart`; an incremental run shows the skipped line labelled
    `as of full scan at HH:mm` (chapter 03 §9 rule 2).
  - `DiskTree.nodes` stays `public internal(set)`; `Incremental.update` and `Snapshot.save` take a lock-guarded busy
    flag (chapter 01 §5.6, 03 §6.5); the build has no new warnings.

### F-035 · Say why a snapshot was not used

- **Area** scan · **Owner** macos-engineer · **Priority** P3 · **Depends on** F-005 · **Chapters** 03 §6.4
- **Acceptance**
  - `Snapshot.load` returns `Result<DiskTree, Snapshot.LoadFailure>` with the six cases of chapter 03.
  - `fil scan -v` prints `snapshot not used: <case>`; `list`/`clean --timings` add it to the load line.
  - A test per case.

### F-036 · Source comments and help text follow the repository rules

- **Area** scan · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-037 · **Chapters** README (Decisions)
- **Acceptance**
  - No comment in `Sources/` refers to a product outside this repository (today `Scan.swift:6`,
    `Cleanup.swift:37`).
  - Help text and comments point to `docs/design/02-size-accounting.md` instead of `docs/specs/accounting.md`
    (`main.swift` scan help, `Firmlinks.swift`).
  - The snapshot magic comment matches the on-disk byte order.

### F-037 · `docs/specs` replaced by `docs/design`

- **Area** design · **Owner** designer · **Priority** P2 · **Depends on** — · **Chapters** 02, 04
- **Acceptance**
  - `docs/specs/accounting.md` and `docs/specs/cleanup-rules.md` each contain one line pointing to the chapter
    that supersedes them.
  - `CLAUDE.md` points to `docs/design/` and lists `doctor` among the commands.

### F-047 · FSEvents checks are reliable and say why they fall back

- **Area** scan · **Owner** scan-tester · **Priority** P2 · **Depends on** — · **Chapters** 03 §11
- **Acceptance**
  - Every `scripts/verify.sh` scenario that expects `incremental` prints the `-v` reason when it gets a full scan.
  - `scripts/verify.sh` run 20 times in a row: flake rate per scenario reported; seen once so far: `hardlink: grow
    via link A` (full scan instead of incremental) and the ScanCore test "a folder that becomes readable again is
    walked". Each flaky case gets a cause or an issue for `macos-engineer`.

### F-048 · Sizes on FAT volumes match `du`

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 02 §1.1, §6; 01 §3.2, §5.3
- **Acceptance**
  - A file record without `ATTR_FILE_ALLOCSIZE` counts its data length rounded up to the allocation unit
    (`statfs(root).f_bsize`, once per scan or update); a directory's own allocation (`ATTR_DIR_ALLOCSIZE`, else its
    rounded `ATTR_DIR_DATALENGTH`; root from its `lstat`) is counted in its own node, as in chapter 02 §1.1.
  - On a FAT image made with `hdiutil create -fs MS-DOS` holding a 300 KB file, a 3-byte file and a subfolder,
    `fil scan <mount> --full --top 0 --porcelain` `alloc=` equals `du -skx <mount>` × 1024 (today `alloc=0`, `du`
    320 KB); the same for the subfolder. An automated test builds the image.
  - `scripts/verify.sh` on APFS passes unchanged; the full-scan time stays within the chapter 01 §12 budget.
  - Chapter 02 "As built" lists the file systems checked (FAT32, exFAT at least).

### F-020 · ScanCore regression tests

- **Area** scan · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-004, F-006, F-007 · **Chapters** 01 §13; 03 §11
- **Acceptance**
  - `swift test` covers: dataless files and directories (not entered); device crossing (`mountsSkipped`); each
    `UpdateFailure` case reachable in tests (`historyUntrusted`, `historyTimeout`, `barrierTimeout`,
    `volumeChanged`, `rootUnreadable`); snapshot rejection on mode or version; concurrent registry claims;
    non-ASCII and case-only renames in an incremental update.
  - Cases already required by F-004, F-006, F-007 are not duplicated.

---

## M2 · Safe cleaning

### F-002 · Tool-reported cache paths cannot select user folders

- **Area** clean · **Owner** macos-engineer · **Priority** P0 · **Depends on** — · **Chapters** 04 §6.7.2, §6.7.3
- **Acceptance**
  - A reported path is accepted only when it is at least two components below home and contains the tool's
    name or a cache marker (chapter 04 §6.7.2); otherwise it is ignored with a `skippedCommands` line.
  - A reported path that is not the tool's default location is `careful` with note `customCacheLocation`.
  - Tests: `PIP_CACHE_DIR=~/Projects`, `HOMEBREW_CACHE=~/Developer` (ignored); `~/x/pip-cache` (careful).

### F-003 · Trash re-check resolves every ancestor and the item's identity

- **Area** clean · **Owner** macos-engineer · **Priority** P0 · **Depends on** — · **Chapters** 04 §3.3, §7
- **Acceptance**
  - Right before the move, each parent is opened without following symlinks and the item's device and inode
    equal the `FileID` stored at scan time; after the move the result is checked again (`movedOtherItem`).
  - Tests: symlinked ancestor, item replaced by another folder, item on another device: all `pathChanged` or
    `movedOtherItem`, nothing moved.

### F-008 · Command removals are labelled permanent

- **Area** clean · **Owner** macos-engineer · **Priority** P1 · **Depends on** — · **Chapters** 04 §3.2; 05 §6.2, §6.3
- **Acceptance**
  - Dry run prints `would run: <argv>` for command candidates and a separate footer saying these are removed by
    the tool and cannot be restored from the Trash.
  - README Safety model states the exception.

### F-014 · Removal commands time out and run in their own session

- **Area** clean · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 04 §7
- **Acceptance**
  - Removal commands run with the query runner's session options; after 600 s SIGTERM, 5 s later SIGKILL;
    outcome `Failure.timedOut`.
  - Ctrl-C during `clean --yes` stops the running command.
  - Test with a fake command that hangs (short timeout injected).

### F-038 · `project-artifacts` ignores projects in the Trash

- **Area** clean · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 04 §6.8
- **Acceptance**
  - No `project-artifacts` candidate lies under `~/.Trash`; chapter 04 §6.8 states it (open question closed).
  - Test with a `node_modules` + `package.json` fixture under the fixture home's `.Trash`.

### F-013 · A dry run writes nothing

- **Area** cli · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 05 §9
- **Acceptance**
  - `fil clean <id>` without `--yes` writes neither the snapshot nor `tool-paths.json` (checked with
    `FIL_SNAPSHOT_DIR` on an empty folder: still empty afterwards).
  - README "touches nothing" stays true.

### F-021 · CLI and CleanCore regression tests

- **Area** clean · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-002, F-003, F-014 · **Chapters** 04 §7; 05
- **Acceptance**
  - `swift test` covers: `list --json` schema keys; `NO_COLOR`, `--no-color` and non-TTY plain output; dry run vs
    `--yes` output; `app-caches` with a running app; `.venv`, `Pods`, `Package.swift` manifests; a failing
    removal command.
  - Cases already required by F-002, F-003, F-014 are not duplicated.

---

## M3 · Releases you can trust

### F-022 · Release runs the tests first

- **Area** ops · **Owner** release-engineer · **Priority** P0 · **Depends on** — · **Chapters** 07 §12, §13.1
- **Acceptance**
  - `release.yml` has jobs `test`, `build`, `publish`, `tap`; `build` needs `test` (`swift build -c release`,
    `swift test`).
  - A manual `workflow_dispatch` run on `main` shows `test` passing and `publish`/`tap` skipped.
  - `CONTRIBUTING.md` has the "Releasing (maintainer)" checklist of chapter 07 §13.1.

### F-039 · The published checksum file verifies

- **Area** ops · **Owner** release-engineer · **Priority** P1 · **Depends on** — · **Chapters** 07 §6, §11.4
- **Acceptance**
  - The `.sha256` file is one line `<64 hex>  fil-X.Y.Z-arm64.tar.gz` (no absolute path).
  - `shasum -a 256 -c fil-X.Y.Z-arm64.tar.gz.sha256` passes in a folder with both downloads (checked on a
    `workflow_dispatch` artifact).

### F-023 · Pinned actions, least-privilege tokens, Dependabot

- **Area** ops · **Owner** release-engineer · **Priority** P1 · **Depends on** F-022 · **Chapters** 07 §13.2
- **Acceptance**
  - Every `uses:` is a 40-character SHA with the tag as a comment, resolved with `gh api` (never from memory).
  - `ci.yml` `permissions: contents: read`; `release.yml` top-level `permissions: {}`, only `publish` has
    `contents: write`; checkouts use `persist-credentials: false`.
  - `.github/dependabot.yml` for `github-actions` and `swift`.

### F-024 · The cask is rendered, checked and audited before it is pushed

- **Area** ops · **Owner** release-engineer · **Priority** P1 · **Depends on** F-022 · **Chapters** 07 §12, §13.3
- **Acceptance**
  - `packaging/homebrew/fil.rb.in` is the cask template; every substitution is checked with `grep -qxF`.
  - `brew audit --cask --strict --online` and an install of the new cask run before the push.
  - Keys, certificate and `known_hosts` live in `$RUNNER_TEMP` and are removed in an `if: always()` step; GitHub's
    host keys come from `api.github.com/meta`.

### F-025 · Quote every expansion in `scripts/release.sh`

- **Area** ops · **Owner** release-engineer · **Priority** P3 · **Depends on** — · **Chapters** 07 §11.1, §13.4
- **Acceptance**
  - All variable expansions in `scripts/release.sh` are quoted (`set -euo pipefail` is already there).
  - `scripts/verify*.sh` carry a comment saying `-e` is left out on purpose.

### F-028 · Changelog, templates and a format check

- **Area** ops · **Owner** release-engineer · **Priority** P2 · **Depends on** F-022 · **Chapters** 07 §13.6
- **Acceptance**
  - `CHANGELOG.md` (Keep a Changelog) with 0.1.0 and 0.1.1; release notes come from it.
  - `.github/ISSUE_TEMPLATE/bug.yml` (asks for `fil --version`, macOS version, `fil doctor --no-open` output),
    `PULL_REQUEST_TEMPLATE.md`, `CODEOWNERS`.
  - `.swift-format` and a `swift format lint --strict` CI step; the one-time reformat commit is listed in
    `.git-blame-ignore-revs`.

### F-029 · CLA check that exists

- **Area** ops · **Owner** release-engineer · **Priority** P2 · **Depends on** F-023 · **Chapters** 07 §13.7
- **Acceptance**
  - `.github/workflows/cla.yml` (pinned `contributor-assistant/github-action`) storing signatures on branch
    `cla-signatures`; `CONTRIBUTING.md` and `CLA.md` describe exactly that.

### F-030 · Project-only agent settings; CLAUDE.md current

- **Area** ops · **Owner** release-engineer · **Priority** P2 · **Depends on** — · **Chapters** 07 §13.8
- **Acceptance**
  - `.claude/settings.json` and `.claude/agents/*.md` contain only project-relevant entries;
    `.claude/settings.local.json` is added to `.gitignore` (it is not ignored today).

### F-040 · Owner actions for M3

- **Area** design · **Owner** owner (issue written by designer) · **Priority** P1 · **Depends on** F-023, F-028,
  F-029 · **Chapters** 07 §14
- **Acceptance**
  - One issue lists each action with the choice made for now and "Confirm or revert": `main` ruleset requiring CI
    (with admin bypass so direct pushes keep working), branch `cla-signatures`, Dependabot enabled, repository
    topics and homepage, the six release secrets still valid.
  - Closed when the owner has done or declined each.

### F-031 · Improvement plan (tracking) — **withdrawn**

- Replaced by the GitHub milestones of this roadmap. Close with a pointer to `docs/design/08-roadmap.md`.

### F-046 · not used

- Number taken by Dependabot pull request #46.

---

## M4 · Scriptable CLI

### F-009 · Each command accepts only its own options

- **Area** cli · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-001 · **Chapters** 05 §1.4, §5.2, §6.1
- **Acceptance**
  - Unknown or foreign options: `fil: unknown option <opt> for 'fil <command>'`, exit 2 (`fil list --yes`,
    `fil clean --bogus`).
  - `--home` without a value is a usage error, exit 2. `--timings` is listed in help.
  - Parser tests per command.

### F-010 · Numeric options and DIR count are validated

- **Area** cli · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-009, F-011 · **Chapters** 05 §3.1
- **Acceptance**
  - `-j` and `--top` take integers (`-j` ≥ 1, `--top` ≥ 0); anything else is a usage error, exit 2.
  - A second DIR: `more than one directory given`, exit 2.
  - `fil scan -j 0` never writes a snapshot (today it saves an empty tree).

### F-041 · `--` ends option parsing

- **Area** cli · **Owner** macos-engineer · **Priority** P3 · **Depends on** F-009 · **Chapters** 05 §1.4
- **Acceptance**
  - `fil scan -- -weird-dir` scans a directory named `-weird-dir`; test.

### F-012 · Documented, distinct exit codes

- **Area** cli · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-001, F-009 · **Chapters** 05 §7
- **Acceptance**
  - 0 success, 1 error, 2 usage error, 3 partial `clean --yes` failure; `fil clean` with no selector is a usage
    error.
  - Each command's help ends with its exit status; tests cover every code.

### F-042 · `fil clean --json`

- **Area** cli · **Owner** macos-engineer · **Priority** P2 · **Depends on** F-009, F-012 · **Chapters** 05 §6.4
- **Acceptance**
  - Output matches the schema of chapter 05 §6.4 (`dryRun`, `items[]` with `outcome`, `argv`, `trashPath`,
    `error`, `leftOut`, `totals`) for a dry run and `--yes`; keys are only ever added.
  - Test decoding both against the schema.

### F-026 · README and help match the binary

- **Area** cli · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-009, F-010, F-012, F-042 · **Chapters**
  05 §10
- **Acceptance**
  - README lists every option of every command (incl. `--naive`, `--tolerant-hardlinks`, `--home`, `-V`,
    `--timings`) and an "Exit status" section.
  - README says only `alloc` equals `du -skx`, the headline is clone-aware; describes `NO_COLOR` as the code
    behaves; says `--porcelain` fields are only appended.
  - A test fails when an option in `--help` is missing from README.

---

## M5 · Scales

### F-043 · Benchmark harness and performance budget

- **Area** scan · **Owner** scan-tester · **Priority** P0 · **Depends on** — · **Chapters** 01 §12
- **Acceptance**
  - `scripts/bench.sh` builds a fixed generated fixture (≥ 1 M files under `/private/tmp`), runs `--full -j 8`
    3× interleaved and an incremental update after 1,000 changes, and prints medians.
  - Baseline numbers for the current `main` are recorded in chapter 01 "As built".

### F-044 · Timing laps for the full scan

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 01 §11
- **Acceptance**
  - With `FIL_TIMINGS=1`, a full scan prints laps `scan.walk`, `scan.originals`, `scan.totals`.

### F-016 · Incremental update cost follows the changes

- **Area** scan · **Owner** macos-engineer · **Priority** P1 · **Depends on** F-043 · **Chapters** 01 §6.4; 03 §5.5, §10
- **Acceptance**
  - Registry `forget` touches only affected directories (per-directory index); `affected` is sparse.
  - `scripts/bench.sh`: an update after 1,000 changes on the 1 M-file fixture is at least 5× faster than before;
    full scan within budget.

### F-017 · Child lookup by name is not linear

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** F-043 · **Chapters** 01 §5.5; 03 §5.1, §10
- **Acceptance**
  - Directories above a child-count threshold get a lazily built name index; lookups allocate no `String`.
  - Bench: 10,000 events in a directory of 100,000 children update in under 1 s.

### F-018 · Hard-link claims are batched per directory

- **Area** scan · **Owner** macos-engineer · **Priority** P2 · **Depends on** F-043 · **Chapters** 01 §4.4, §12
- **Acceptance**
  - At most one `HardlinkRegistry` lock per directory (chapter 01 per-directory budget).
  - Bench on a fixture with 200,000 hard links: full scan time not worse, lock count per directory ≤ 1.

### F-049 · Folders keep their identity across updates

- **Area** scan · **Owner** macos-engineer · **Priority** P3 · **Depends on** F-043 · **Chapters** 03 §5.2, §6.5; 01 §5.1,
  §12, As built (#7)
- **Why M5:** the case needs an incomplete re-read of the parent (an I/O error mid-directory) and a same-named
  folder recreated in the same window, and the parent is already flagged incomplete, so the number is not shown as
  exact. The fix costs 8 bytes per folder (`DirNode` stride 96 → 104), which M5 measures with F-043, and touches
  the update child diff that F-016 and F-017 also change. The snapshot section is optional, so it needs no format
  change in v0.2.0.
- **Acceptance**
  - `DirNode.fileID` holds the directory's `ATTR_CMN_FILEID` (root: `st_ino`); `MemoryLayout<DirNode>.stride == 104`
    and chapter 01 §12 says so.
  - In an update, a known child whose stored non-zero `fileID` differs from its listing, or from the `lstat` of an
    unlisted child after an incomplete re-read, is killed and walked as new (chapter 03 §5.2).
  - Test (`Incremental.applyTracked` with one event on `P`, re-read of `P` made incomplete by the `DirFaults` hook,
    `bulk` `EIO`): after `P/C` is deleted and recreated with other contents, `C`'s total equals `du -skx P/C` × 1024
    and `P` stays incomplete. The same test fails before the change.
  - Snapshot section tag 7 (not must-understand): round trip keeps every `fileID`; a format-6 file without it loads
    with `fileID = 0` and updates as before; a count other than the node count is `corrupt`.
  - `scripts/bench.sh`: full scan and update within the chapter 01 §12 budget.

---

## M6 · Map

### F-019 · Map layout uses clone-aware sizes

- **Area** map · **Owner** macos-engineer · **Priority** P1 · **Depends on** — · **Chapters** 06 §8
- **Acceptance**
  - `MapSource` has `totalCloneAware`/`ownCloneAware`; `MapSizeMode` (default `.cloneAware`) picks the size;
    `MapLayout.seconds` is removed.
  - Layout tests of chapter 06 §8.4 pass, including a clone family counted once.

---

## M7 · Finishing touches

### F-027 · Shell completions and a man page

- **Area** cli · **Owner** macos-engineer · **Priority** P2 · **Depends on** F-012, F-026 · **Chapters** 05 §8
- **Acceptance**
  - `fil completion zsh|bash|fish` prints a completion script covering every command and option; `man/fil.1`
    exists and `man ./man/fil.1` renders.
  - A test fails when a command or option is missing from the completions.

### F-045 · Completions and man page ship in the tarball and cask

- **Area** ops · **Owner** release-engineer · **Priority** P2 · **Depends on** F-027, F-024 · **Chapters** 07 §11.3,
  §13.5
- **Acceptance**
  - The release tarball contains `completions/fil.zsh`, `completions/fil.bash`, `completions/fil.fish` and
    `man/fil.1`; the cask template installs them with `zsh_completion`, `bash_completion`, `fish_completion`,
    `manpage`.
  - A `workflow_dispatch` artifact shows the files; `brew audit` passes.

### F-050 · The concurrent tool query test uses tools that really hang

- **Area** clean · **Owner** macos-engineer · **Priority** P2 · **Depends on** — · **Chapters** 04 §5.1, §5.3, §11
- **Why M7:** M2, where the test was written (#21), is closed. The test passes today and `fil` behaves correctly;
  only the proof is missing, so nothing user-facing waits for it. M5 is about scan speed against the F-043 budget,
  which this test is not part of; M7 holds the remaining polish.
- **Acceptance**
  - `grep -n '"/bin/sleep"' Tests/CleanCoreTests/ToolTests.swift` finds nothing; the test writes a fixture script
    (`exec /bin/sleep 60`, mode 755) that `locate` returns for every tool.
  - The test checks that all seven cache tools have a note ending `timed out after 1 s; using the default
    location`, that elapsed ≥ 1 s, and that elapsed < 3.5 s (half of 7 queries × 1 s in a row).
  - `swift test --filter CleanCoreTests.TimeoutTests` passes five times in a row.
  - With `CacheTools.discover` changed locally to await each query in turn (not committed), the test fails.
