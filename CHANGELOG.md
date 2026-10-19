# Changelog

All notable changes to Fil are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-19

### Added

- `fil completion zsh|bash|fish` and a man page; the tarball and the Homebrew cask install both (#27, #45).
- `fil clean --json` prints the plan or the result as JSON (#42).
- `--` ends option parsing (#41).
- `FIL_TIMINGS=1` prints timing laps of the full scan; `scripts/bench.sh` measures scans and update rounds (#44, #51).
- The release workflow can push the Homebrew cask again for an existing release (#24).

### Changed

- Each command accepts only its own options (#9); `-j`, `--top` and the number of directories are validated (#10).
- Exit statuses have one meaning each: 1 error, 2 usage, 3 a failed clean item, 130 interrupted (#12).
- README and `--help` match the binary (#26).
- Faster full scans of trees with many folders or hard links: registry records are indexed by directory, children
  are looked up by name through an index, and hard links are claimed under one lock per directory (#16, #17, #18).
- The treemap lays out clone-aware sizes (#19).

### Fixed

- An incremental update tells a folder deleted and recreated under the same name from the old one and rescans it
  (#49).
- An incremental update fails, and a full scan runs instead, when the fseventsd log is missing changes; before, it
  could show stale sizes as current (#51).
- The release workflow pushes the Homebrew cask to the tap (#24).

## [0.2.0] - 2026-10-18

### Added

- `fil doctor` checks Full Disk Access and warns when a scan skipped an unreadable folder.
- Styled CLI output: live scan progress, size bars and a folder tree.
- Cleanup rules read paths from the tools themselves (`brew`, `docker`, `xcrun simctl`, ...) through
  swift-subprocess, never through a shell string.
- Firmlinked data and APFS clone families are counted once (`docs/design/02-size-accounting.md`).
- Snapshot format 6 records the cross-devices mode and the mounts seen during the scan (#5).
- `scripts/verify.sh` covers a volume mounted and unmounted inside the scanned root (#4).
- CI actions pinned by commit SHA, least-privilege workflow tokens and Dependabot (#23).
- The release workflow runs the build and tests before signing (#22).
- The release workflow renders, audits and installs the Homebrew cask before pushing it to the tap (#24).
- After an incremental update the skipped counters are labelled "as of full scan at HH:mm"; `denied` is always
  current (#15).
- One snapshot per root and mode, and `-v` says why a snapshot was not used (#33, #35).
- Regression tests for the scan engine, the CLI and the cleanup rules (#20, #21); `scripts/verify.sh` prints why
  an expected incremental run fell back (#47).
- `swift format lint --strict` runs in CI (#28).
- Design documents, roadmap and backlog under `docs/design/`; `docs/specs/` points to them (#37).
- `CHANGELOG.md`, issue form, pull request template and `CODEOWNERS`; the release notes come from the changelog.

### Changed

- `fil scan DIR` resolves `DIR` with `realpath` and rejects a missing path or a non-directory (#11).
- Errors end the program with a message instead of a crash (#1).
- `scripts/release.sh` quotes every expansion (#25).
- Removal commands are labelled permanent in `fil clean` output (#8).
- Removal commands time out and run in their own session; Ctrl-C stops a clean at once, exits 130 and never
  reports an interrupted command as done (#14).
- A dry run writes nothing: no snapshot and no `tool-paths.json` (#13).

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
- Folders whose names are not valid UTF-8 are scanned by their bytes (#6).
- A directory listing that stops early marks the folder incomplete instead of reporting a short size as exact (#7).
- A folder that disappears during a scan is no longer reported as unreadable (#34).
- Sizes on FAT and exFAT volumes, and of a volume mounted inside the root, match `du` (#48).
- `project-artifacts` ignores projects in the Trash (#38).

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

[Unreleased]: https://github.com/productdevbook/fil/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/productdevbook/fil/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/productdevbook/fil/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/productdevbook/fil/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/productdevbook/fil/releases/tag/v0.1.0
