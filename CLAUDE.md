# Fil

Fast disk scanner and cleaner for macOS. The scan engine is the product: it must be faster than anything
built on FileManager and its sizes must match `du` exactly.

- Target: macOS 27, Apple Silicon only. No support code for older systems or Intel.
- Code, comments and CLI output are in English. The user writes to the orchestrator in Turkish; reply in Turkish.
- Swift Package: `Sources/ScanCore` (engine library), `Sources/MapCore` (treemap layout), `Sources/fil` (the `fil` CLI: `scan`, `doctor`, `list`, `clean`),
  `Sources/CleanCore` (cleanup rules, spec: `docs/specs/cleanup-rules.md`).
- External commands (`xcrun`, `brew`) run through swift-subprocess, never a shell string.
- Build: `swift build -c release`. Verify: `.build/release/fil scan <dir> --full --top 0` vs `du -skx <dir>`.
- Release: `docs/design/07-build-and-release.md`; never run `scripts/release.sh` or push tags unless asked.
- Deleting user files means moving them to the Trash; never unlink user data.
- This repository is public (GPL-3.0). Do not add references to the separate, proprietary desktop app.

## Engine rules

- `getattrlistbulk` per directory, parallel workers (default 8: beyond that the APFS kernel is the limit).
  No per-file syscalls or allocations on the hot path.
- `DiskTree` is a flat array of directories; a child's id is always larger than its parent's.
- Hard links count once (`HardlinkRegistry`); cloud placeholders (`SF_DATALESS`) are never entered or
  downloaded; the scan never crosses into another device.
- Incremental updates replay FSEvents since the snapshot's event id. When the history cannot be trusted,
  fall back to a full scan. Never present sizes known to be stale or wrong as current; a clearly labelled
  last-known result ("Results from 12:05") is fine while an update runs or after it failed.

## Agents

- `designer` (Opus): `docs/design/` (chapters, roadmap, backlog) and the GitHub issues; writes no code.
- `macos-engineer` (Sonnet): every change to `Sources/`, `Tests/` and `Package.swift`.
- `release-engineer` (Sonnet): `.github/`, `scripts/release.sh`, `packaging/`.
- `scan-tester` (Haiku): runs `scripts/verify*.sh` and `scripts/bench.sh`, compares against `du`; never edits `Sources/`.

## Planning

`docs/design/` is the source of every issue (playbook: design → roadmap → backlog → issues → agents build →
orchestrator reviews, verifies and closes). Backlog items are `F-NNN`; F-N is GitHub issue #N. Milestones M1–M7 in
`docs/design/08-roadmap.md`. Commits say `Refs #<n>`; agents commit, the orchestrator pushes.

Commit messages follow Conventional Commits: `<type>(<scope>): <summary>` in the imperative, lower case, no
period, at most 72 characters. Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `ci`, `build`, `chore`.
Scopes: `core` (ScanCore), `clean` (CleanCore), `cli`, `map`, `release`, `ci`, `design`. Example:
`fix(core): never count a volume mounted inside the root`. Body, then `Refs #<n>`, then the co-author line.

## Orchestration and cost

- The orchestrator plans, writes briefs and reviews; agents write the code. Agents run on Sonnet
  at `medium`. The orchestrator passes `model: opus` for design, architecture, the contract, money or
  concurrency, and a bug whose cause is unclear; a bug fix in existing code gets `effort: high`.
- A brief names the goal, the files, the check to run, what is out of scope, and asks for a final
  message of at most 300 words; long output goes to a file under /tmp and is referenced by path.
- Agents run in parallel only on independent work; dependent steps of one feature run in order.
- Changes to concurrency, the scan engine's counting rules or permissions are reviewed in a fresh
  context (`/code-review`) before commit; only findings that affect correctness are fixed.
- One feature per session: a large piece of work gets a spec file and is built in a fresh session.

# Compact instructions

Keep the list of changed files, open bugs, the checks that ran and their results, and the decisions
taken; drop tool output.
