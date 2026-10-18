# Contributing to Fil

Thanks for helping. Bug reports, benchmarks, and focused pull requests are welcome.

## Build and test

```sh
swift build              # debug build
swift build -c release   # release build
swift test               # unit tests
scripts/verify.sh        # full verification, run before opening a PR
```

Requires macOS 27 on Apple Silicon.

## Code style

See `CLAUDE.md` for conventions. Follow the existing style in the file you edit.

## Engine rules

These are not negotiable; PRs that break them will not be merged.

1. No per-file syscalls on the hot path. Use bulk calls (`getattrlistbulk`) and batch work across workers.
2. Sizes must match `du -skx` exactly. Hard links are counted once, and iCloud placeholders are never downloaded.
3. Never unlink user data. Cleaning moves items to the Trash only.

Changes to the scan engine should include a before/after benchmark and a comparison against `du`.

## Pull requests

- Keep each PR focused on one change.
- Add or update tests.
- Describe what changed and why.

## Contributor License Agreement (CLA)

Every contributor must sign the [CLA](CLA.md) before a PR can be merged. The CLA Assistant bot comments on your first PR with a link; sign once and it applies to later contributions.

Why: this repository is GPL-3.0, but the author also ships the same engine inside the proprietary Fil desktop app. The CLA gives the author the right to relicense contributions for that purpose. You keep the copyright in your work.
