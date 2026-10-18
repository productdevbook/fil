# 08 · Roadmap

Milestones in build order. Each ships on its own and leaves the released `fil` better than before. Items are in
[backlog.md](backlog.md); F-N is GitHub issue #N.

Order of need: numbers people can trust, then cleaning that cannot hurt, then releases that cannot ship a broken
build, then a CLI scripts can rely on, then speed at scale, then the map library, then finishing touches.

## M1 · Trustworthy numbers

**Goal:** every size `fil` prints is either correct or clearly marked, and no input makes it crash.

Items: F-001, F-011, F-004, F-032, F-005, F-033, F-006, F-007, F-034, F-015, F-035, F-036, F-037, F-047, F-048, F-020.

## M2 · Safe cleaning

**Goal:** `fil clean` can only touch what it listed, checks it again right before touching it, and says exactly
how each item goes away.

Items: F-002, F-003, F-008, F-014, F-038, F-013, F-021.

## M3 · Releases you can trust

**Goal:** a release is built only from a tested commit, with least-privilege pinned workflows, a checksum users can
verify, and a cask that is audited before it is published.

Items: F-022, F-039, F-023, F-024, F-025, F-028, F-029, F-030, F-040. Withdrawn: F-031.

## M4 · Scriptable CLI

**Goal:** every command validates its input, documents its exit status and has machine-readable output, and the
README matches the binary.

Items: F-009, F-010, F-041, F-012, F-042, F-026.

## M5 · Scales

**Goal:** incremental updates cost what changed, not what exists, measured against a fixed budget.

Items: F-043, F-044, F-016, F-017, F-018, F-049.

F-049 (folder identity) is a correctness fix placed here, not in M1: the case is rare and already flagged
incomplete, it raises the memory budget (8 bytes per folder) that F-043 measures, and it changes the same update
child diff as F-016 and F-017. Its snapshot section is optional, so v0.2.0's format 6 does not wait for it.

## M6 · Map

**Goal:** the treemap layout ranks folders by real on-disk (clone-aware) size.

Items: F-019.

## M7 · Finishing touches

**Goal:** `fil` installs with shell completions and a man page.

Items: F-027, F-045.

## Orders that cannot change

- F-022 (tests before release) and F-039 (checksum file) merge before the next tag, or the next release can ship
  untested or with a checksum `shasum -c` rejects.
- F-005, F-015 and F-033 all change the snapshot file; they ship in the same release as snapshot format 6, so the
  format changes once. F-015 and F-033 build on F-005.
- F-011 (resolve DIR) ships before or with F-033 (snapshot per root and mode): the snapshot key must be the
  resolved path.
- F-012 (exit codes) before F-042 (`clean --json`) and F-026 (README), which document them.
- F-043 (benchmark harness) before F-016, F-017, F-018: their acceptance is measured with it.
- F-027 (CLI) before F-045 (packaging).
- F-019 changes the public MapCore API: it ships in a minor release.

## Releases

| Release | Carries | Why |
|---|---|---|
| v0.2.0 | M1, M2, M3 | Snapshot format 6 and safety fixes; M3 gates the tag itself. |
| v0.3.0 | M4 | Exit codes and option validation change behaviour scripts see. |
| v0.4.0 | M5, M6 | Performance and a MapCore API change. |
| v0.5.0 | M7 | Completions and man page in the tarball and cask. |

## Role agents

| Agent | Model / effort | Owns | Status |
|---|---|---|---|
| `designer` | opus / high | `docs/design/`, `backlog.md`, GitHub issues and milestones. Writes no code. | new |
| `macos-engineer` | sonnet / medium (opus for engine counting rules, concurrency, unclear bugs) | `Sources/`, `Tests/`, `Package.swift` | exists, rewrite to playbook format |
| `release-engineer` | sonnet / medium | `.github/`, `scripts/release.sh`, `packaging/`, release parts of `CONTRIBUTING.md` | new |
| `scan-tester` | haiku / medium | `scripts/verify*.sh`, `scripts/bench.sh`; runs the binary, reports pass/fail with numbers. Never edits `Sources/`. | exists, rewrite to playbook format |

Bake-off result: see README Decisions (2026-10-18). Models were confirmed by a blind bake-off on one real item per role before M1 starts (macos-engineer: F-001;
release-engineer: F-039; scan-tester: the F-004 scenario; designer: the F-040 issue text), recorded as a decision.
Every agent file gets `disallowedTools: Agent` and only that: no list of unrelated tools.

## Summary

| Milestone | Items | IDs | scan | clean | cli | map | ops | design |
|---|---|---|---|---|---|---|---|---|
| M1 · Trustworthy numbers | 16 | F-001, F-004–F-007, F-011, F-015, F-020, F-032–F-037, F-047, F-048 | 13 | 0 | 2 | 0 | 0 | 1 |
| M2 · Safe cleaning | 7 | F-002, F-003, F-008, F-013, F-014, F-021, F-038 | 0 | 6 | 1 | 0 | 0 | 0 |
| M3 · Releases you can trust | 9 (+1 withdrawn) | F-022–F-025, F-028–F-031, F-039, F-040 | 0 | 0 | 0 | 0 | 8 | 1 |
| M4 · Scriptable CLI | 6 | F-009, F-010, F-012, F-026, F-041, F-042 | 0 | 0 | 6 | 0 | 0 | 0 |
| M5 · Scales | 6 | F-016–F-018, F-043, F-044, F-049 | 6 | 0 | 0 | 0 | 0 | 0 |
| M6 · Map | 1 | F-019 | 0 | 0 | 0 | 1 | 0 | 0 |
| M7 · Finishing touches | 2 | F-027, F-045 | 0 | 0 | 1 | 0 | 1 | 0 |
| **Total** | **47 (+1 withdrawn, 1 not used)** | F-001–F-049 | 19 | 6 | 10 | 1 | 9 | 2 |
