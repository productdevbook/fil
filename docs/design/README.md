# Fil design

The whole of Fil in this repository: the scan engine, size accounting, incremental updates, cleanup rules, the
`fil` command line, the treemap layout library, and how it is built and released. Each chapter starts from the
code as it is today. Work is planned in [08-roadmap.md](08-roadmap.md) and itemised in [backlog.md](backlog.md).
The design is the source of every issue: to change a rule, change the chapter first.

| Chapter | Covers |
|---|---|
| [01 · Scan engine](01-scan-engine.md) | `getattrlistbulk` reader, workers, `DiskTree`, hard links, dataless files, devices, stats, performance budget |
| [02 · Size accounting](02-size-accounting.md) | `alloc`, `cloneaware`, `shared`, private mode, firmlinks, APFS clone families (supersedes `docs/specs/accounting.md`) |
| [03 · Incremental updates and snapshots](03-incremental-and-snapshots.md) | FSEvents replay, `UpdateFailure`, snapshot file format, last-known results |
| [04 · Cleanup](04-cleanup.md) | Rules, safety levels, tool queries, selection, removal (supersedes `docs/specs/cleanup-rules.md`) |
| [05 · Command line](05-cli.md) | Every command, option, output line, porcelain/JSON format, exit status, state files |
| [06 · Map layout](06-map-layout.md) | MapCore: squarified treemap and two-level layout |
| [07 · Build and release](07-build-and-release.md) | Package, CI, verify scripts, signing, notarization, GitHub release, Homebrew cask, repository files |
| [08 · Roadmap](08-roadmap.md) | Milestones in build order |
| [Backlog](backlog.md) | Every work item, `F-001`…`F-049` |

## Status tags

Every point in a chapter carries one:

- **[Exists]**: in the code today, with a file reference.
- **[Change]**: in the code, changed by this design; the reason and the issue are given.
- **[New]**: not in the code yet.

## Pillars

1. **Correct or clearly marked.** A size Fil prints as current is right. Anything stale, partial or uncertain says
   so on the same line; nothing silently under- or over-counts.
2. **Trash, never unlink, and say how it goes.** Fil moves user data to the Trash. Where a tool's own command
   removes something (simulators, Go caches, Docker), the output says it is permanent before it runs.
3. **Speed is the product.** No per-file syscall, lock or allocation on the hot path; every engine change is
   measured against the budget in chapter 01.
4. **Never surprise a script.** `--porcelain` fields and JSON keys are only added, never removed or retyped. Exit
   codes are documented and stable.
5. **Ask the tool, but trust nothing it says blindly.** Tool-reported paths and on-disk state are checked again
   right before anything is touched.
6. **macOS 27 on Apple Silicon only.** No compatibility code for older systems or Intel.

## Decisions

Approved decisions already recorded in `CLAUDE.md` (2026-10-18):

- 2026-10-18: Target macOS 27, Apple Silicon only.
- 2026-10-18: Sizes must match `du -skx` (`alloc`); the headline number is the clone-aware size (`cloneaware`).
- 2026-10-18: `getattrlistbulk` per directory, 8 workers by default; `DiskTree` is a flat array, a child's id is
  larger than its parent's.
- 2026-10-18: Hard links count once; dataless placeholders are never entered; the scan never crosses devices.
- 2026-10-18: Incremental updates replay FSEvents; untrusted history means a full scan; never present stale sizes
  as current, a labelled last-known result is allowed.
- 2026-10-18: Deleting user files means moving them to the Trash.
- 2026-10-18: External commands run through swift-subprocess, never a shell string.
- 2026-10-18: The repository is public (GPL-3.0) and does not refer to products outside it.

Approved by the owner with this design (2026-10-18):

- Backlog prefix `F-`. Issues #1–#31 already exist, so `F-001`…`F-031` are those issues (F-N is issue #N); new
  items start at `F-032` and are created in ID order, so the rule F-N = #N holds for every item.
- `docs/design/` replaces `docs/specs/`; the two old spec files become one-line pointers (F-037).
- Snapshot format 6 is introduced once, in v0.2.0, and carries every M1 format change (F-005, F-015, F-033).
- Exit status: 0 success, 1 error, 2 usage error, 3 partial `clean` failure (F-012). Doctor keeps 0/1.
- A dry-run `fil clean` writes nothing at all: no snapshot, no `tool-paths.json` (F-013).
- Command removals time out after 600 s; SIGTERM, then SIGKILL 5 s later (F-014).
- A tool-reported cache path must be at least two components below home and contain the tool's name or a cache
  marker; a path that is not the tool's default location is `careful` (F-002).
- The release workflow is four jobs (`test`, `build`, `publish`, `tap`); the cask is rendered from a template in
  this repository (F-022, F-024).
- Semantic Versioning; before 1.0 a minor release may change the MapCore API or exit codes.
- Role agents `designer`, `macos-engineer`, `release-engineer`, `scan-tester` ([08-roadmap.md](08-roadmap.md#role-agents)).
- 2026-10-18 bake-off (same item, two models, worktrees, judged on acceptance, correctness and diff):
  `macos-engineer` on #1: both passed; Opus gave cleaner system-error messages, Sonnet a smaller diff. Default
  Sonnet / medium; Opus for engine counting rules, concurrency, unclear bugs (as before). `release-engineer` on
  #39: identical results; Sonnet / medium. `designer` on #40: Opus clearly better (checked live repository state,
  ordered steps by dependency, kept M7 items out of M3); Opus / high. `scan-tester` on the #4 verify.sh
  scenario: both correct; Sonnet's diff smaller and clearer. Haiku runs and reports checks; Sonnet writes new
  scenarios and scripts.

## Glossary and canonical IDs

One name per thing, used in every chapter, issue, option and field. Add new IDs here first.

### Commands and options

`scan`, `doctor`, `list`, `clean`, `help`, `completion` (new, F-027). Options keep their CLI spelling
(`--full`, `--top`, `-j`, `--private`, `--porcelain`, `--tolerant-hardlinks`, `--naive`, `-q`, `-v`, `--no-color`,
`--home`, `--json`, `--yes`, `--no-open`, `--timings`).

### Sizes and scan results

| ID | Meaning |
|---|---|
| `alloc` | Allocated bytes, hard links once; equals `du -skx` × 1024. With `--private`: private bytes. |
| `cloneaware` | "On disk": `alloc` with each APFS full-clone family counted once. Ranks the tree. |
| `shared` | `alloc - cloneaware`. |
| private mode | `--private`: sizes from `ATTR_CMNEXT_PRIVATESIZE`. |
| own / total | A directory's own files vs. its whole subtree. |
| unreadable | A folder that could not be opened (permission). Porcelain `unreadable=`. |
| incomplete directory | Opened, but the read stopped early or entries were dropped (new, F-007). Counted in `unreadable=`. |
| uncertain bytes | Tolerant mode: bytes of hard links that may be counted twice. Porcelain `uncertain=`. |
| strict / tolerant hard links | `scan` default / `--tolerant-hardlinks`, `list`, `clean`. |
| dataless | `SF_DATALESS` cloud placeholder; never entered or downloaded. |

### Engine

`DiskTree`, node, dead node, `DirReader`, `ScanOptions`, `ScanStats`, `HardlinkRegistry`, `CloneRegistry`, clone
family, original, full / partial clone, firmlink, alias, data root, `FirmlinkTable`, `rawNames` (F-006),
`checkOwnDevice` (F-004), allocation unit (F-048), `DirNode.fileID` / folder identity (F-049).

### Incremental updates and snapshots

snapshot, snapshot format (5 today, 6 from v0.2.0), mode byte, event id, barrier, history / live / finished phase,
lost-history flags, shallow re-read, full rescan, drift, orphan, last-known result. `UpdateFailure` cases:
`rootUnreadable`, `volumeChanged`, `historyUntrusted`, `historyTimeout`, `barrierTimeout`, `streamFailed`,
`unattributedHardLink`, `firmlinksChanged`. `Snapshot.LoadFailure` cases (F-035): `missing`, `notSnapshot`,
`otherVersion`, `otherMode`, `otherRoot`, `corrupt`.

### Cleanup

Rule ids: `xcode-derived`, `xcode-device-support`, `simulators-unavailable`, `simulator-runtimes`,
`xcode-archives`, `homebrew-cache`, `pkg-caches`, `project-artifacts`, `app-caches`, `logs`, `docker`, `trash`.
Safety: `safe`, `review`, `careful`. Removal: `trash`, `command`, `none`. Candidate id
`<rule id>:<path relative to home>`; selector (a rule id or candidate id); left-out item; info-only candidate;
command removal; custom cache location; claim; `skippedCommands`; tool path cache (`tool-paths.json`).

### CLI

porcelain line, dry run, usage error, partial failure, responsible app (the terminal app `doctor` checks).

### Map

`MapSource`, tile, rest tile, files tile, expanded tile, size mode (`MapSizeMode`).

### Build and release

Developer ID, notarization, stapling, Gatekeeper wait, tap (`productdevbook/tap`), cask, cask template
(`packaging/homebrew/fil.rb.in`), runner image `xcode-27`, SHA pin, release gate, CLA check.

### Planning

| ID | Meaning |
|---|---|
| `F-NNN` | Backlog item; F-N is GitHub issue #N. Never reused; withdrawn items stay listed. A number GitHub gives to something else first (e.g. a Dependabot PR) is listed as **not used** and skipped. |
| `M1`…`M7` | Roadmap milestones; inserted ones get fractional numbers (M2.5). |
| `P0`…`P3` | Milestone fails without it / expected / welcome / later. |
| Areas | `scan`, `clean`, `cli`, `map`, `ops`, `design`. |
