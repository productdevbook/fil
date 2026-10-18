<p align="center">
  <img src="branding/fil-icon.svg" width="128" alt="Fil logo">
</p>

# Fil

A very fast disk scanner and cleaner for macOS 27 (Apple Silicon only).

"Fil" is Turkish for elephant. An elephant never forgets; Fil remembers your disk.

## Why it is fast

- Reads directories in bulk with `getattrlistbulk` instead of one syscall per file, spread across parallel workers.
- The `alloc` size matches `du -skx` exactly; the headline size also counts each APFS clone family once. Hard links are counted once, and iCloud placeholders are never downloaded.
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
fil scan                    # scan the home folder
fil scan ~/Projects --top 20
fil scan / --full -j 8      # full rescan with 8 workers
fil scan --private          # count only non-shared (clone) blocks
fil scan --porcelain        # stable output for scripts
fil scan -q                 # no warning about unreadable folders
fil scan -- -odd-name       # a directory whose name starts with a dash

fil doctor                  # check Full Disk Access for your terminal app (opens System Settings if missing)
fil doctor --no-open        # only print; exit 0 = granted, 1 = missing or unknown

fil list                    # list cleanable items and rules
fil list --json

fil clean <id|rule>...      # dry run: shows what would move to the Trash or which command would run
fil clean <id|rule>... --yes
fil clean <id|rule>... --json
fil help <command>          # same as fil <command> --help
fil --version               # prints "fil 0.2.0"; also -V
```

Options of `fil scan [DIR]`:

| Option | Meaning |
| --- | --- |
| `-j N` | worker threads, a whole number from 1 to 64 (default 8) |
| `--private` | size in private bytes only: excludes blocks shared by APFS clones |
| `--full` | ignore the snapshot and scan from scratch |
| `--top N` | list the N largest folders (0 = none, default 15) |
| `--naive` | time a plain `FileManager` walk instead; cannot be combined with `--porcelain` |
| `--porcelain` | one machine-readable line, see below |
| `--tolerant-hardlinks` | count unknown hard links and report them as `uncertain` instead of forcing a full scan |
| `-q`, `--quiet` | no warning about folders that could not be read |
| `-v`, `--verbose` | timing details and skipped-entry counts |
| `--no-color` | plain output |

`--` ends option parsing: every later argument is a directory.

Options of `fil doctor`: `--no-open` only prints and does not open System Settings; `--no-color` gives plain output.

Options of `fil list`: `--home DIR` uses DIR instead of the home folder, `--json` prints machine-readable output, `--timings` prints phase and rule timings on stderr, `--no-color` gives plain output.

Options of `fil clean <candidate-id|rule-id>...`: `--home DIR`, `--json`, `--timings` and `--no-color` as for `fil list`, and `--yes` to clean for real (the default is a dry run). A rule id selects its safe and review items; name a careful item by its candidate id.

`-h` and `--help` work on every command. A command accepts only its own options; anything else is a usage error.

### Output

The first line of `fil scan` shows the clone-aware size (each APFS clone family counted once), the headline number. Only the `alloc` figure equals `du -skx`, which counts clones again; `shared` is the difference. Output is styled (colour, live progress on stderr) only on a terminal, and colour is off when `NO_COLOR` is set or with `--no-color`. Size bars and tree guides are printed the same when piped. The live progress line follows stderr being a terminal and ignores `NO_COLOR`. `fil scan` lists up to 5 folders it could not read, then `... and N more`.

`fil scan --porcelain` prints one `key=value` line on stdout: `mode`, `alloc` (du-compatible), `logical`, `files`, `dirs`, `uncertain` (only with `--tolerant-hardlinks`), `cloneaware`, `shared` (not with `--private`) and `unreadable` (folders that could not be read). Fields are only ever appended, never removed, renamed or reordered, so read them by key.

`fil list --json` prints `{"home", "candidates"}`; each candidate has `id`, `rule`, `path`, `bytes`, `safety`, `note` and `removal`. `fil clean --json` prints one document at the end, for a dry run and for `--yes`: `dryRun`, `home`, `items`, `leftOut` and `totals`. Each item has `id`, `rule`, `path`, `bytes`, `safety`, `removal`, `argv` (the command for a command removal, else null), `outcome`, `trashPath` and `error`. `totals` has `trashBytes`, `commandBytes`, `handled` and `failed`. Keys are only ever added.

### Exit status

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | error: `DIR` or `--home` missing or not a directory, `clean` matches nothing, or `fil doctor` finds Full Disk Access missing or unknown |
| 2 | usage error: unknown command or option, missing or invalid value, more than one `DIR`, `--naive` with `--porcelain` |
| 3 | `clean --yes`: one or more items failed (others may have succeeded) |
| 130 | `clean --yes` interrupted with Ctrl-C; the remaining items were not touched |

### Full Disk Access

Without Full Disk Access, macOS hides folders such as `~/Library/Mail`, `~/Library/Containers/*`, `~/Pictures/Photos Library` and `/private/var/db`, so scan sizes are too low. `fil scan` lists the folders it could not read. A command-line tool cannot ask for the permission and `sudo` does not help: macOS grants it to the terminal app (Terminal, iTerm2, Ghostty, Warp, VS Code, ...). `fil doctor` finds that app, checks the permission (by opening the user TCC database, which only a process with Full Disk Access can read) and opens System Settings → Privacy & Security → Full Disk Access. After enabling it, quit and reopen the terminal. Folders owned by another user are reported separately: Full Disk Access does not change those.

## Safety model

- Fil never deletes files itself: it moves them to the Trash. The exception is a few rules (simulators, Go caches, Docker) that run the tool's own removal command; that removal is permanent, cannot be restored from the Trash, and is marked as such (`would run: <command>`) in the dry run.
- Every cleaning rule has a safety level: `safe`, `review`, or `careful`.
- `fil clean` is a dry run unless you pass `--yes`: it prints what would be moved to the Trash or removed by a tool's command, and changes nothing: no files, no snapshot, no tool-path cache.

## Repository layout

The engine libraries (ScanCore, CleanCore, MapCore) and the `fil` command-line tool.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributors sign a [CLA](CLA.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## License

This repository is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

The name "Fil" and the elephant logo are trademarks of productdevbook and are not covered by the GPL. See [TRADEMARK.md](TRADEMARK.md).

The Fil desktop app for macOS is a separate, proprietary, closed-source product by the same author, built on this engine and licensed commercially. It is not part of this repository.

Copyright (c) 2026 productdevbook.
