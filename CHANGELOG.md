# Changelog

All notable changes to Fil are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `fil doctor` checks Full Disk Access and warns when a scan skipped an unreadable folder.
- Styled CLI output: live scan progress, size bars and a folder tree.
- Cleanup rules read paths from the tools themselves (`brew`, `docker`, `xcrun simctl`, ...) through
  swift-subprocess, never through a shell string.
- Firmlinked data and APFS clone families are counted once (`docs/specs/accounting.md`).
- Snapshot format 6 records the cross-devices mode and the mounts seen during the scan (#5).
- `scripts/verify.sh` covers a volume mounted and unmounted inside the scanned root (#4).
- CI actions pinned by commit SHA, least-privilege workflow tokens and Dependabot (#23).
- The release workflow runs the build and tests before signing (#22).
- The release workflow renders, audits and installs the Homebrew cask before pushing it to the tap (#24).
- Design documents, roadmap and backlog under `docs/design/`.
- `CHANGELOG.md`, issue form, pull request template and `CODEOWNERS`; the release notes come from the changelog.

### Changed

- `fil scan DIR` resolves `DIR` with `realpath` and rejects a missing path or a non-directory (#11).
- Errors end the program with a message instead of a crash (#1).
- `scripts/release.sh` quotes every expansion (#25).

### Fixed

- A volume mounted inside the scanned root is never counted, and mount and unmount events never add another
  volume's files (#4).
- Tool-reported cache paths can only select cache-like folders; the cache marker must be in the folder itself, and
  a damaged path cache is ignored (#2).
- Before moving an item to the Trash, every ancestor and the item's identity are re-checked; a symlinked default
  cache location is treated as careful; a move without a reported destination is no longer called a mix-up (#3).
- A strict scan ignores a snapshot with uncertain bytes (#32).
- Incremental updates never run on a data-volume root, map events of such a root by its firmlink path, and match
  mounts on data-volume roots (#5).
- The release checksum file names the tarball relatively, so `shasum -c` verifies it (#39).

## [0.1.1] - 2026-10-18

### Added

- Release workflow: pushing a tag `vX.Y.Z` signs, notarizes and publishes the release and updates the Homebrew
  cask in `productdevbook/homebrew-tap`.

### Fixed

- `scripts/release.sh` waits until Gatekeeper can see the notarization ticket before the release is published.

## [0.1.0] - 2026-10-18

### Added

- First release. The `fil` command-line tool with `scan`, `list` and `clean`: a parallel `getattrlistbulk` scan
  whose sizes match `du`, incremental updates from FSEvents snapshots, and cleanup that moves items to the Trash.
- `scripts/release.sh` to build, sign with a Developer ID and notarize the arm64 tarball.
- Homebrew install instructions.

[Unreleased]: https://github.com/productdevbook/fil/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/productdevbook/fil/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/productdevbook/fil/releases/tag/v0.1.0
