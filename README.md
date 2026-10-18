<p align="center">
  <img src="branding/fil-icon.svg" width="128" alt="Fil logo">
</p>

# Fil

A very fast disk scanner and cleaner for macOS 27 (Apple Silicon only).

"Fil" is Turkish for elephant. An elephant never forgets; Fil remembers your disk.

## Why it is fast

- Reads directories in bulk with `getattrlistbulk` instead of one syscall per file, spread across parallel workers.
- Sizes match `du -skx` exactly. Hard links are counted once, and iCloud placeholders are never downloaded.
- Later scans update incrementally from FSEvents history instead of walking everything again.

Benchmark, 1.46M files:

| Tool | Time |
| --- | --- |
| Fil | ~7 s |
| `du` | ~40 s |
| `FileManager` | ~42 s |

## Install

Requires macOS 27 on Apple Silicon. The binary is signed with a Developer ID and notarized by Apple.

```sh
brew install --cask productdevbook/tap/fil
```

Homebrew asks you to trust third-party taps; installing by the full name trusts only this cask.
Prebuilt binaries are also attached to each [GitHub release](https://github.com/productdevbook/fil/releases).

## Build

Requires macOS 27 on Apple Silicon and the Swift toolchain.

```sh
git clone https://github.com/productdevbook/fil.git
cd fil
swift build -c release
.build/release/fil --help
```

## Usage

```sh
fil scan                    # scan the default location
fil scan ~/Projects --top 20
fil scan / --full -j 8      # full rescan with 8 workers
fil scan --private          # count only non-shared (clone) blocks
fil scan --porcelain        # stable output for scripts
fil scan -q                 # no warning about unreadable folders

fil doctor                  # check Full Disk Access for your terminal app (opens System Settings if missing)
fil doctor --no-open        # only print; exit 0 = granted, 1 = missing

fil list                    # list cleanable items and rules
fil list --json

fil clean <id|rule>...      # dry run: shows what would move to the Trash
fil clean <id|rule>... --yes
```

Options for `fil scan [DIR]`: `--full` ignores incremental state, `--top N` limits the folder tree, `-j N` sets worker count, `--private` counts only space private to each file (excludes blocks shared by clones), `--porcelain` prints machine-readable output (ends with `unreadable=N`, the number of folders that could not be read), `-q` hides the unreadable-folder warning, `-v` adds timing details, `--no-color` forces plain output.

Output is styled (colour, size bars, live progress on stderr) only on a terminal; it is plain when piped or when `NO_COLOR` is set. `--porcelain` output never changes. `fil list` and `fil clean` also accept `--no-color`.

### Full Disk Access

Without Full Disk Access, macOS hides folders such as `~/Library/Mail`, `~/Library/Containers/*`, `~/Pictures/Photos Library` and `/private/var/db`, so scan sizes are too low. `fil scan` lists the folders it could not read. A command-line tool cannot ask for the permission and `sudo` does not help: macOS grants it to the terminal app (Terminal, iTerm2, Ghostty, Warp, VS Code, ...). `fil doctor` finds that app, checks the permission (by opening the user TCC database, which only a process with Full Disk Access can read) and opens System Settings → Privacy & Security → Full Disk Access. After enabling it, quit and reopen the terminal. Folders owned by another user are reported separately: Full Disk Access does not change those.

## Safety model

- Cleaning only moves items to the Trash. Fil never deletes files.
- Every cleaning rule has a safety level: `safe`, `review`, or `careful`.
- `fil clean` is a dry run unless you pass `--yes`: it prints what would move to the Trash and touches nothing.

## Repository layout

The engine libraries (ScanCore, CleanCore, MapCore) and the `fil` command-line tool.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributors sign a [CLA](CLA.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## License

This repository is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

The name "Fil" and the elephant logo are trademarks of productdevbook and are not covered by the GPL. See [TRADEMARK.md](TRADEMARK.md).

The Fil desktop app for macOS is a separate, proprietary, closed-source product by the same author, built on this engine and licensed commercially. It is not part of this repository.

Copyright (c) 2026 productdevbook.
