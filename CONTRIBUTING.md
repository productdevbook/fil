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

Every contributor must sign the [CLA](CLA.md) before a PR can be merged. The CLA check (`.github/workflows/cla.yml`) comments on your first pull request. To sign, reply with exactly: `I have read the CLA Document and I hereby sign the CLA`. Your signature is recorded on the `cla-signatures` branch and covers later contributions. Comment `recheck` to run the check again.

Why: this repository is GPL-3.0, but the author also ships the same engine inside the proprietary Fil desktop app. The CLA gives the author the right to relicense contributions for that purpose. You keep the copyright in your work.

## Releasing (maintainer)

1. Update `let version` in `Sources/fil/main.swift` and move the `## [Unreleased]` entries in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`.
2. Locally: `swift test`, `scripts/verify.sh`, `scripts/verify-clean.sh` (all must end with every check passed).
3. Commit `fil X.Y.Z` on `main`, push, and wait for CI `build-and-test` to pass.
4. `git tag -a vX.Y.Z -m "fil X.Y.Z" && git push origin vX.Y.Z`. The release workflow runs the tests, then signs, notarizes, publishes and updates the Homebrew cask.
5. After the workflow: `brew update && brew upgrade --cask fil && fil --version`.
