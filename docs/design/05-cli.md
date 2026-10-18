# 05 · The `fil` command line

The CLI is Fil's only user interface in this repository, so its output is the product's set of screens. This
chapter specifies every command, option, line of output, exit status and file the CLI writes, in the order a
user sees them. It covers `Sources/fil/main.swift`, `Scan.swift`, `Cleanup.swift`, `UI.swift` and
`Permissions.swift`.

Status tags:

- **[Exists]**: the code does this today (file reference given). Captured from `swift build -c release` and
  `.build/release/fil` 0.1.1, run on a fixture under `/private/tmp` with `FIL_SNAPSHOT_DIR` set.
- **[Change]**: the code must change to this; the reason and the GitHub issue are given.
- **[New]**: does not exist yet and has no issue of its own.

Where this chapter and the code disagree, the code describes what exists today and this chapter describes
the target.

---

## 1. Global conventions

### 1.1 Streams

- **[Exists]** Results go to stdout. Live progress, `--timings` output and error messages go to stderr
  (`main.swift:72-80`, `UI.swift:107-152`, `Cleanup.swift:34-36`).
- **[Exists]** Usage errors print the message, a blank line, then the main help or the command's help, to
  stderr (`main.swift:77-80`).
- **[Change] (#1)** Every error message on stderr starts with `fil: `. A usage error is two lines:

  ```
  fil: <message>
  Run 'fil help <command>' for usage.
  ```

  (`Run 'fil --help' for usage.` when no command was recognised.) The full help block is no longer printed
  after a usage error. Reason: the help is 15-20 lines and pushes the one line that matters off the screen.
- **[Change] (#1)** No error ever ends the process with a Swift "Fatal error" (today exit 133, e.g.
  `fil scan /nonexistent/x`). The dispatch in `main.swift:103-114` is wrapped in `do/catch`; a caught error
  prints `fil: <message>` and exits 1. The message is the error's `description` for our own error types and
  `localizedDescription` for system errors, with the path in front when one is known:
  `fil: /nonexistent/x: No such file or directory`.
- **[Change] (#1)** A failed snapshot save is not fatal: the scan result is correct, only the cache is
  missing. stderr gets `fil: warning: could not save the snapshot (<reason>); the next run does a full scan`
  and the command continues with its normal output and exit status.
- **[Change] (#1)** With `--porcelain` or `--json`, an error prints nothing on stdout (no partial line or
  partial JSON), only the stderr message.

### 1.2 Styling

- **[Exists]** Colour is on only when all hold: no `--no-color`, stdout is a TTY (`isatty(1)`), `NO_COLOR`
  is unset or empty, `TERM` is not `dumb` (`UI.swift:11-14`). Every command that prints human output calls
  `UI.setup(noColor:)` before printing.
- **[Exists]** SGR codes: bold `1`, dim `2`, red `31`, green `32`, yellow `33`, cyan `36` (spinner frame
  only); each styled span ends with `\e[0m` (`UI.swift:16-21`).
- **[Exists]** Share colouring of a size or bar: share of the total >= 20 % red, >= 5 % yellow, else plain
  (`UI.swift:23-26`).
- **[Exists]** Safety labels are padded to 7 characters: `safe` green, `review` yellow, `careful` red
  (`UI.swift:46-53`).
- **[Exists]** Layout does not depend on colour: size bars, tree guides and column padding are printed the
  same when piped. Only the SGR codes disappear.
- **[Exists]** Terminal width comes from `TIOCGWINSZ` on fd 1; 80 when that fails (always 80 when piped)
  (`UI.swift:28-32`).
- **[Exists]** Paths under the user's home are shown as `~` or `~/…` (`UI.tilde`, `UI.swift:55-59`). JSON
  and porcelain output never shorten paths.

### 1.3 Number and time formats

All locale independent.

| Kind | Rule | Examples | Source |
| --- | --- | --- | --- |
| Size | Decimal (1000) units like Finder; `< 1000` → `N B`; else one decimal with `KB`/`MB`/`GB`/`TB`, moving up when the value would round to 1000.0; TB is the last unit | `512 B`, `7.6 MB`, `105.3 GB` | **[Exists]** `UI.swift:71-80` |
| Count | Thousands separated with `,` | `1,234,567` | **[Exists]** `UI.swift:96-105` |
| Duration | `< 1 s` → `N ms`; `< 60 s` → `N.N s`; else `Nm SSs` | `850 ms`, `1.4 s`, `2m 05s` | **[Exists]** `UI.swift:87-94` |
| Timing (`-v`, `--timings`) | Whole milliseconds | `148 ms` | **[Exists]** `UI.swift:82-85` |
| Percent (tree) | `<1%` below 0.5 %, else rounded whole percent | `69%` | **[Exists]** `Scan.swift:194` |

### 1.4 Argument parsing

- **[Exists]** The first argument is the command; options and positional arguments of a command can come in
  any order (`main.swift:88-114`).
- **[Exists]** `--help` or `-h` anywhere after a command prints that command's help on stdout and exits 0
  (`main.swift:104, 107, 110`).
- **[Exists]** An option that needs a value and is last on the line is a usage error `<option> needs a
  value`, exit 2 (`main.swift:83-86`). Exception: `--home` without a value exits 1 with `--home needs a
  directory` (`Cleanup.swift:19`).
- **[Change] (#9)** `--home` uses the same `takeValue` path as every other option: usage error, exit 2.
- **[New]** `--` ends option parsing; every later argument is positional. Reason: a directory whose name
  starts with `-` cannot be scanned today.
- **[Change] (#9)** Each command accepts only its own options (tables below). Anything else is a usage
  error: `fil: unknown option <opt> for 'fil <command>'`, exit 2. Today `list` and `clean` share one parser
  and silently accept each other's options and stray arguments (`fil clean --json <id>`,
  `fil list --yes xyz` both exit 0).

---

## 2. Top level

### 2.1 Commands and global options

| Invocation | Effect | Status |
| --- | --- | --- |
| `fil scan [DIR] …` | Section 3 | **[Exists]** |
| `fil doctor …` | Section 4 | **[Exists]** |
| `fil list …` | Section 5 | **[Exists]** |
| `fil clean <id\|rule>… …` | Section 6 | **[Exists]** |
| `fil help` | Main help on stdout, exit 0 | **[Exists]** `main.swift:96-102` |
| `fil help <command>` | That command's help on stdout, exit 0; unknown command → usage error `unknown command '<name>'`, exit 2 | **[Exists]** `main.swift:97-99` |
| `fil --help`, `fil -h` | Main help, exit 0 | **[Exists]** `main.swift:92-93` |
| `fil --version`, `fil -V` | `fil 0.1.1` (the `version` constant) on stdout, exit 0 | **[Exists]** `main.swift:94-95` |
| `fil` (nothing) | Usage error `missing command`, exit 2 | **[Exists]** `main.swift:89` |
| `fil <other>` | Usage error `unknown command '<other>'`, exit 2 | **[Exists]** `main.swift:112-113` |
| `fil completion <zsh\|bash\|fish>` | Section 8 | **[Change] (#27)** |

`fil help completion` prints the completion help. `fil help help` is the main help **[Change] (#26)**
(today a usage error).

### 2.2 Main help text

**[Exists]** `main.swift:5-20`. **[Change] (#26, #27, #12)** target text, printed byte for byte:

```
Usage: fil <command> [options]

Commands:
  scan [DIR]          Scan a directory and print its size (default: home folder)
  doctor              Check Full Disk Access for the terminal app
  list                List cleanup candidates in the home folder
  clean <id|rule>...  Clean candidates (dry run unless --yes)
  completion <shell>  Print a completion script for zsh, bash or fish
  help [command]      Show help for a command

Options:
  --help, -h          Show this help
  --version, -V       Print the version

Exit status:
  0  success
  1  error (doctor: Full Disk Access missing or unknown)
  2  usage error
  3  clean --yes: one or more items failed

Run 'fil help <command>' for details.
```

Changes against today: `-V` listed; `completion` added; `clean` no longer says "Move … to the Trash" because
some rules run commands (#8); "Exit status" section added (#12, #26).

---

## 3. `fil scan [DIR]`

Scans one directory tree and prints its size. **[Exists]** `Scan.swift:7-164`.

### 3.1 Options

| Option | Value | Default | Today's validation | Target validation | Status |
| --- | --- | --- | --- | --- | --- |
| `DIR` | path | home folder (`NSHomeDirectory()`) | `standardizingPath` only; several DIRs keep the last one; relative paths stay relative (`.` stays `.`) | Exactly zero or one; resolved with `realpath(3)`; must exist (`fil: <arg>: No such file or directory`, exit 1) and be a directory (`fil: <arg>: not a directory`, exit 1); a second DIR is a usage error `more than one directory given`, exit 2 | **[Change] (#10, #11)** |
| `-j N` | integer | 8 (`ScanOptions.threads`) | `Int(…) ?? 8`: `abc` silently becomes 8, `0` accepted | Whole number 1-64, else usage error `-j needs a whole number from 1 to 64, got '<v>'`, exit 2. 64 caps thread creation; throughput already plateaus at 8 | **[Change] (#10)** |
| `--top N` | integer | 15 | `Int(…) ?? 15`; negative behaves as 0 | Whole number >= 0, else usage error `--top needs a whole number of 0 or more, got '<v>'`, exit 2; `0` = no tree | **[Change] (#10)** |
| `--private` | — | off | — | — | **[Exists]** sizes are bytes private to each file (excludes blocks shared by clones) |
| `--full` | — | off | — | — | **[Exists]** ignore the snapshot, scan from scratch (the snapshot is still written) |
| `--naive` | — | off | — | Usage error with `--porcelain`: `--naive cannot be combined with --porcelain` (its line is not porcelain) | **[Exists]** / **[Change] (#9)** |
| `--porcelain` | — | off | — | — | **[Exists]** one machine-readable line, 3.4 |
| `--tolerant-hardlinks` | — | off (strict) | — | — | **[Exists]** an unknown old hard link is counted and reported as `uncertain` instead of forcing a full scan |
| `-q`, `--quiet` | — | off | — | — | **[Exists]** no unreadable-folder warning |
| `-v`, `--verbose` | — | off | — | — | **[Exists]** timing and skipped-entry block |
| `--no-color` | — | off | — | — | **[Exists]** |
| `-h`, `--help` | — | — | — | — | **[Exists]** |

`-q` and `-v` have no effect with `--porcelain`; this is not an error **[Exists]**.

**[Change] (#11)** The resolved path is used everywhere: as the snapshot key, in the header, and for the
scan itself. Today `fil scan /tmp` scans the symlink and reports `alloc=0 … unreadable=1`, exit 0, and
`fil scan .` stores a snapshot keyed by the literal `.`, so `fil scan .` from two different directories
loads the same snapshot. The porcelain line gets no path field: paths may contain spaces and would break
`key=value` splitting.

### 3.2 Help text

**[Exists]** `main.swift:22-44`. **[Change] (#12, #26)**: append, after the existing last paragraph, a blank
line and

```
Exit status: 0 success, 1 error (DIR missing or not a directory), 2 usage error.
```

### 3.3 Human output, in order

Example (fixture, piped, `--full`):

```
.  7.6 MB on disk
7.6 MB logical · 3 files · 5 folders · 1 ms · full scan

Largest folders
   5.2 MB  █████████████▊         69%  a/b
   2.1 MB  █████▌                 27%  c

1 folder could not be read (permission denied); sizes below it are missing.
  ./c/locked  (no permission)
```

After #11 the first line reads `/private/tmp/fil-cli-design/tree  7.6 MB on disk` and the warning path is
absolute (or `~/…`).

1. **Progress (stderr).** **[Exists]** `UI.swift:107-152`, `Scan.swift:63-65, 93`.
   - Shown only when stderr is a TTY and `TERM` is not `dumb`; never with `--porcelain` or `--naive`.
     `NO_COLOR`/`--no-color` do not hide it; they only remove its colour (colour follows the stdout rule
     in 1.2).
   - Redrawn every 100 ms as `\r\e[K` + line. Line: spinner frame (cycling `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, cyan) + ` Scanning`;
     when at least one folder was read, dim `  <folders> folders · <files> files · <size>`; then dim
     `  <elapsed>`. Example: `⠼ Scanning  1,204 folders · 18,330 files · 2.1 GB  1.4 s`.
   - It also runs during an incremental update, where the counters stay at zero and only the time moves.
   - Cleared with `\r\e[K` before any stdout output.
2. **Unattributed hard links.** **[Exists]** `Scan.swift:120`. Only when the incremental update was refused
   because of unknown hard links (strict mode): one line per path, `  unattributed hard link: <path>`,
   before the header.
3. **Header.** **[Exists]** `Scan.swift:124`. Bold root path (tilde form), two spaces, bold total, then dim
   ` on disk` (clone-aware bytes) or ` private` (with `--private`).
4. **Status line.** **[Exists]** `Scan.swift:125-126`, dim:
   `<logical> logical · <files> files · <folders> folders · <duration> · <summary>`. `folders` includes the
   root. `<summary>` is one of `full scan`, `up to date from snapshot`,
   `updated from snapshot, <N> change` / `<N> changes` (N with thousands separators).
5. **Shared line.** **[Exists]** `Scan.swift:127-129`. Only when shared bytes > 0 (never with `--private`),
   dim: `<shared> shared by clones, counted once (du without clone dedupe: <alloc>)`.
6. **Uncertain line.** **[Exists]** `Scan.swift:130-132`. Only when uncertain bytes > 0, yellow:
   `<size> uncertain (hard links that may be counted twice)`.
7. **Verbose block.** **[Exists]** `Scan.swift:133-143`. Only with `-v`, dim: a blank line,
   `timing   <ms> [<mode>]`, `         snapshot saved in <ms>`; on a full scan also
   `skipped  denied <n> · errors <n> · hardlinks <n> · mounts <n> · cloud-dirs <n> (cloud files <size>)`
   and `         firmlinked data dirs <n> · clone files counted once <n>`. `<mode>` is `full scan`,
   `full scan (incremental not usable: <reason>)` or
   `incremental: load <ms>, <n> events in <ms>, apply <ms> (<n> dirs re-read, <n> subtrees walked, <n> removed)`.
8. **Tree.** **[Exists]** `Scan.swift:151-203`. Skipped when `--top 0` or the total is 0.
   - Selection: every directory except the root that is not dead, holds more than 1/200 of the total, and
     whose largest child holds less than 90 % of it (a parent that is mostly one child is skipped; the
     child stands for it). Sorted by size descending, first N kept. Size = clone-aware bytes, or private
     bytes with `--private`.
   - Placement: each row sits under its nearest listed ancestor; siblings by size descending. The label is
     the path relative to that ancestor, so skipped intermediate folders show as `a/b`.
   - Blank line, bold `Largest folders`, then one row per directory:
     `lpad(size, 9)` + 2 spaces + 20-cell bar + 2 spaces + `lpad(percent, 4)` + 2 spaces + dim guide + label.
     Size and bar take the share colour of 1.2.
   - Bar: 20 cells in eighths, `█` for full cells and `▏▎▍▌▋▊▉` for the remainder, padded with spaces to 20.
   - Guides: depth 0 none; deeper rows `├─ ` or `└─ ` (last sibling), continued with `│  ` or `   `.
   - The label is shortened in the middle with `…` to `max(8, width − 37 − guide length)` characters.
9. **Unreadable warning.** **[Exists]** `Scan.swift:145-150`, `Permissions.swift:16-74`. Printed last (after
   the tree), unless `-q`; only when some folder could not be read. A blank line, then yellow lines:
   - `<n> folder could not be read (permission denied); sizes below it are missing.` (plural:
     `folders`, `them are`).
   - Up to 5 paths, `  <path>` + `  (owned by another user)` or `  (no permission)`; privacy-protected
     ones have no suffix. Order: privacy-protected, other user, no permission; then shallow before deep;
     then by path.
   - `  … and <n> more` when more than 5.
   - When any is privacy-protected: `` Give <terminal app> Full Disk Access: run `fil doctor` `` (the app
     is found as in 4.2; `your terminal app` when none is found).
   - When any is owned by another user:
     `Folders owned by another user cannot be read without their permission; Full Disk Access does not change that.`
   - Classification: privacy-protected when under `/private/var/db`, `/var/db`,
     `/Library/Application Support/com.apple.TCC`, or `~/Library`, `~/Pictures`, `~/Desktop`,
     `~/Documents`, `~/Downloads`, `~/Movies`, `~/Music`; otherwise "other user" when the folder's owner
     uid differs from ours; otherwise "no permission".

`--naive` replaces all of the above with one line **[Exists]** `Scan.swift:40-56`:
`naive  <size>  <files> files  <ms>` (file count without separators; FileManager walk, no snapshot read or
written).

### 3.4 `--porcelain` line

**[Exists]** `Scan.swift:110-117`. Exactly one line on stdout, no styling, no progress, no warning:

```
mode=incremental alloc=7647232 logical=7647232 files=3 dirs=5 cloneaware=7647232 shared=0 unreadable=1
```

Fields, space separated, `key=value`, values are base-10 integers except `mode`:

| # | Field | Present | Meaning |
| --- | --- | --- | --- |
| 1 | `mode` | always | `full` or `incremental` (the result came from a snapshot plus FSEvents) |
| 2 | `alloc` | always | Allocated bytes, du-compatible (`du -skx` × 1024 matches); with `--private`, private bytes |
| 3 | `logical` | always | Sum of logical file sizes |
| 4 | `files` | always | Files counted (hard links once) |
| 5 | `dirs` | always | Directories including the root |
| 6 | `uncertain` | only with `--tolerant-hardlinks` | Bytes of hard links that may be counted twice |
| 7 | `cloneaware` | always | Allocated bytes with each APFS clone family counted once |
| 8 | `shared` | not with `--private` | `alloc − cloneaware`: bytes du counts again for clones |
| 9 | `unreadable` | always | Folders that could not be read (all kinds; `-q` does not change it) |

Compatibility rule **[Exists]** (help text, `Scan.swift:111`): fields are never removed, renamed or
reordered, and new fields are added only at the end of the line. Parsers must split on spaces and read
`key=value` pairs by key, because `uncertain` and `shared` are conditional. Exit status follows section 7; on
error nothing is printed on stdout **[Change] (#1)**.

---

## 4. `fil doctor`

Checks whether the terminal app running fil has Full Disk Access. **[Exists]** `Permissions.swift:76-196`.

### 4.1 Options

| Option | Value | Default | Validation | Status |
| --- | --- | --- | --- | --- |
| `--no-open` | — | off (opens System Settings when access is missing) | — | **[Exists]** |
| `--no-color` | — | off | — | **[Exists]** |
| `-h`, `--help` | — | — | — | **[Exists]** |
| anything else | | | usage error `unknown option <a> for 'fil doctor'`, exit 2 | **[Exists]** |

### 4.2 Finding the terminal app

**[Exists]** `ResponsibleApp.find`, `Permissions.swift:103-123`.

1. Start at `getpid()`. For each pid, read its executable path with `proc_pidpath` and its parent with
   `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` → `kp_eproc.e_ppid`.
2. In each executable path take the outermost `.app` component
   (`/A/Code.app/Contents/Frameworks/H.app/Contents/MacOS/H` → `/A/Code.app`).
3. Walk up until pid 1 (launchd), a pid that is its own parent, or 64 steps. The bundle found nearest to
   launchd wins, so the terminal is chosen over a helper app or shell wrapper inside it.
4. Display name: `CFBundleName`, else `CFBundleDisplayName`, else the bundle's file name without `.app`.
5. No bundle (ssh session, launchd job): the name is `your terminal app`.

### 4.3 Checking Full Disk Access

**[Exists]** `FullDiskAccess.probe`, `Permissions.swift:128-140`. Full Disk Access is granted to the
responsible app and inherited by fil, so fil tests its own access:

1. `open("~/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)` (the user TCC database, readable
   only with Full Disk Access). Success → **granted**. `EPERM`/`EACCES` → **denied**.
2. Otherwise (for example `ENOENT`): `opendir("~/Library/Safari")`. Success → **granted**;
   `EPERM`/`EACCES` → **denied**.
3. Otherwise → **unknown**.

The database is opened and closed; it is never read or parsed.

### 4.4 Output and exit status

Granted (exit 0):

```
✓ Full Disk Access is granted to Terminal.
```

Unknown (exit 1; System Settings is not opened):

```
? Could not tell whether Terminal has Full Disk Access (the probe files do not exist).
```

Denied (exit 1):

```
✗ Terminal does not have Full Disk Access.

Without it, protected folders (~/Library/Mail, ~/Library/Containers, Photos Library, /private/var/db)
are skipped and scan sizes are too low. `sudo` does not help.

1. Open System Settings → Privacy & Security → Full Disk Access.
2. Turn on Terminal (use + to add it if it is not listed).
3. Quit and reopen Terminal, then run `fil doctor` again.

Opening System Settings…
```

- Marks: `✓` green, `?` yellow, `✗` red (`Permissions.swift:173-179`).
- Without `--no-open`, after the steps: a blank line, `Opening System Settings…`, then
  `/usr/bin/open x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles`
  through `SystemCommandRunner` (argv, no shell) with a 10 s timeout. If that fails, a yellow line
  `Could not open System Settings; open it by hand.` Exit status is 1 either way.
- With `--no-open`, the output stops after step 3.

Help text **[Exists]** `Permissions.swift:144-156` already ends with
`Exit status 0 when Full Disk Access is granted, 1 otherwise.` **[Change] (#12)**: reword to
`Exit status: 0 granted, 1 missing or unknown, 2 usage error.`

---

## 5. `fil list`

Lists cleanup candidates in the home folder. **[Exists]** `Cleanup.swift:7-107`.

### 5.1 What runs

**[Exists]** `Cleanup.swift:37-68`.

1. External tool queries (simctl, docker, cache locations of brew, npm, yarn, go, pip3, …) start at once, so
   they overlap step 2. They run only when `--home` resolves to the real home; otherwise none runs and a
   `Skipped: external commands (not the real home)` line appears.
2. The home tree is loaded from its snapshot and updated from FSEvents, or scanned in full when there is no
   usable snapshot. Hard links are tolerant here (`strictHardlinks: false`). No progress line is shown.
3. The snapshot is saved, or only advanced when nothing changed.
4. Every rule runs in `Rules.all` order: `xcode-derived`, `xcode-device-support`, `simulators-unavailable`,
   `simulator-runtimes`, `xcode-archives`, `homebrew-cache`, `pkg-caches`, `project-artifacts`, `app-caches`,
   `logs`, `docker`, `trash`. Candidates are sorted by bytes, descending.

### 5.2 Options

| Option | Value | Default | Validation | Status |
| --- | --- | --- | --- | --- |
| `--home DIR` | path | `NSHomeDirectory()` | today `standardizingPath` only, relative stays relative; target: `realpath`, must be a directory (exit 1 as in 3.1) | **[Exists]** / **[Change] (#11)** |
| `--json` | — | off | — | **[Exists]** |
| `--timings` | — | off | — | **[Exists]**, undocumented; **[Change] (#9)**: listed in help as `--timings   phase and rule timings on stderr` |
| `--no-color` | — | off | — | **[Exists]** |
| `-h`, `--help` | — | — | — | **[Exists]** |
| `--yes`, positional arguments | | | today accepted and ignored; target: usage error, exit 2 (`unknown option --yes for 'fil list'`, `unexpected argument '<a>' for 'fil list'`) | **[Change] (#9)** |

### 5.3 Human output, in order

```
Cleanup candidates  ~

Project build output and dependencies  1.0 MB  1 item · project-artifacts
  Files inside your coding projects that the project's tools can rebuild or download again.
     1.0 MB  review   ~/proj/node_modules  (node_modules, manifest untouched 0 days)
             id project-artifacts:proj/node_modules -> trash

App caches  3.1 MB  1 item · app-caches
  Temporary files that apps keep to start faster; they recreate them when needed.
     3.1 MB  safe     ~/Library/Caches/com.example.app
             id app-caches:Library/Caches/com.example.app -> trash

Total removable  4.2 MB  (19 ms)
Move items to the Trash with: fil clean <id|rule> --yes
```

1. **Header** **[Exists]** `Cleanup.swift:93`: bold `Cleanup candidates`, two spaces, home (tilde form).
2. **One group per rule** with candidates, in `Rules.all` order **[Exists]** `Cleanup.swift:94-101`:
   - blank line; bold `<rule title>  <total>`, then dim `  <n> item(s) · <rule id>`;
   - dim `  <rule explanation>`;
   - per candidate: `  ` + `lpad(size, 9)` + `  ` + safety label + `  ` + path (tilde form), then dim
     `  (<note>)` when the candidate has a note;
   - under it, dim: 13 spaces + `id <candidate id> -> <removal>`. `<removal>` is `trash`, `info only`, or
     the command's argv joined with spaces.
   - **[Change] (#8)** for a command removal the text becomes `runs: <argv> (permanent)`.
3. **Skipped lines** **[Exists]** `Cleanup.swift:102`: per skipped external query, a blank line and yellow
   `Skipped: <reason>`.
4. **Total** **[Exists]** `Cleanup.swift:103-104`: blank line, bold `Total removable  <size>`, dim
   `  (<duration>)`. Info-only candidates (the Trash) are excluded.
5. **Hint** **[Exists]** `Cleanup.swift:105`: dim `Move items to the Trash with: fil clean <id|rule> --yes`.
   **[Change] (#8)**: `Preview with: fil clean <id|rule>   Clean with: fil clean <id|rule> --yes`, because
   command rules do not use the Trash.

`--timings` writes to stderr before stdout output **[Exists]** `Cleanup.swift:34-68`: two-space indented
rows `snapshot load`, `incremental update  (<n> events[, <n> uncertain bytes])` or
`(not usable: <why>; full scan)`, `full scan`, `snapshot save  [(advance only)]`, `rules total`, one
four-space indented row per rule (`%.1f ms`), `total`. Names are padded to 22 characters (rules to 24).

### 5.4 `--json` schema

**[Exists]** `Cleanup.swift:79-87`. Pretty-printed, keys sorted, `/` escaped as `\/` (JSONSerialization),
one trailing newline. No colour, no `Skipped` lines, no total.

```json
{
  "candidates" : [
    {
      "bytes" : 3145728,
      "id" : "app-caches:Library\/Caches\/com.example.app",
      "note" : null,
      "path" : "\/Users\/me\/Library\/Caches\/com.example.app",
      "removal" : "trash",
      "rule" : "app-caches",
      "safety" : "safe"
    }
  ],
  "home" : "\/Users\/me"
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `home` | string | Home folder the rules ran against (absolute after #11) |
| `candidates` | array of object | Sorted by `bytes` descending |
| `candidates[].id` | string | Candidate id, `<rule>:<path relative to home>` or `<rule>:<key>`; the selector for `clean` |
| `candidates[].rule` | string | Rule id (one of the 12 in 5.1) |
| `candidates[].path` | string | Absolute path |
| `candidates[].bytes` | integer | Bytes freed when cleaned (Docker: Docker's own estimate) |
| `candidates[].safety` | string | `safe`, `review` or `careful` |
| `candidates[].note` | string or null | English note, e.g. `app is running`, `macOS component`, `Empty the Trash in Finder`, `<kind>, manifest untouched <n> days`, `<runtime>, no simulator uses it`, `size reported by Docker; its disk image shrinks later` |
| `candidates[].removal` | string | `trash`, `info only`, or the command's argv joined with single spaces |

Compatibility rule **[New]**: keys are only added, never removed or retyped. Reason: `scripts/verify-clean.sh`
and user scripts parse it.

---

## 6. `fil clean <id|rule>...`

Cleans the named candidates. Dry run unless `--yes`. **[Exists]** `Cleanup.swift:109-165`. Steps 1-4 of 5.1
run first, then selection.

### 6.1 Options and selectors

| Option / argument | Value | Default | Validation | Status |
| --- | --- | --- | --- | --- |
| `<id\|rule>...` | candidate id or rule id, one or more | — | none given: today `clean needs at least one candidate id or rule id`, exit 1; target usage error, exit 2. Unknown: `nothing matches '<s>'`, exit 1 (stays 1: it depends on the disk, not the syntax) | **[Exists]** / **[Change] (#12)** |
| `--home DIR` | path | home | as in 5.2 | **[Exists]** / **[Change] (#11)** |
| `--yes` | — | off (dry run) | — | **[Exists]** |
| `--json` | — | off | today accepted and ignored | **[Change] (#9)**, 6.4 |
| `--timings` | — | off | as in 5.2 | **[Exists]** / **[Change] (#9)** documented |
| `--no-color` | — | off | — | **[Exists]** |
| `-h`, `--help` | — | — | — | **[Exists]** |

Selection **[Exists]** `Engine.swift:114-130`: a candidate id selects that candidate, `careful` ones included.
A rule id selects that rule's `safe` and `review` candidates; its `careful` ones are "left out" and must be
named by their own id. Selector order is kept and duplicates are removed. Info-only candidates can be
selected but do nothing.

### 6.2 Dry run output (no `--yes`)

Today **[Exists]** `Cleanup.swift:115-127`:

```
Would move to the Trash  ~
     3.1 MB  safe     app-caches:Library/Caches/com.example.app  -> trash
     1.0 MB  review   project-artifacts:proj/node_modules  -> trash

Would free 4.2 MB once the Trash is emptied.
Dry run, nothing moved; add --yes to do it.
```

Rows: `  lpad(size, 9)  <safety>  <id>` + dim `  -> <trash | info only | argv>`. Left-out careful items follow
with dim `  not selected, name its id to remove`. The footer total counts every chosen item, info-only ones
too.

Target **[Change] (#8)**:

```
Would clean  ~
     3.1 MB  safe     app-caches:Library/Caches/com.example.app  -> Trash
     2.0 GB  review   simulators-unavailable:…  -> would run: xcrun simctl delete unavailable
     1.2 GB  careful  xcode-archives:…  not selected, name its id to remove

Would move 3.1 MB to the Trash; space is freed once the Trash is emptied.
Would remove 2.0 GB permanently with the tools' own commands; this cannot be undone from the Trash.
Dry run, nothing changed; add --yes to do it.
```

1. Bold `Would clean`, two spaces, home.
2. Chosen rows in selection order. Target text (dim): `-> Trash`, `-> would run: <argv>`, `-> info only`.
3. Left-out careful rows, unchanged.
4. Blank line. `Would move <X> to the Trash; …` only when some chosen item is a Trash removal.
   `Would remove <Y> permanently …` (yellow) only when some chosen item runs a command; argv shared by
   several candidates is counted once per candidate, as today. Info-only items count in neither.
   When neither applies: `Nothing to clean among the selected items.`
5. Yellow `Dry run, nothing changed; add --yes to do it.`

**[Change] (#13)** A dry run writes nothing: no snapshot save or advance (`Cleanup.swift:61` is skipped
when `--yes` is absent), and the tool queries get a `ToolEnvironment` with `pathCache: nil`, so
`tool-paths.json` is not written either. The snapshot is still read. Cost: the next command replays the same
FSEvents again, which is cheap. This makes the README's "touches nothing" true.

### 6.3 `--yes` output

Today **[Exists]** `Cleanup.swift:129-164`, one row per chosen item in order, no header:

| Outcome | Row |
| --- | --- |
| moved to Trash | `  ✓ <size>  <id>` + dim `  -> <path in Trash>` |
| command ran | `  ✓ <size>  <id>` + dim `  ran command` |
| same argv already ran | `  ✓ <size>  <id>` + dim `  done by the same command` |
| info only | `  - <9 spaces>  <id>` + dim `  nothing to do (<note>)` |
| failed | `  ✗ <size>  <id>` + red `  failed: <reason>` (`path changed or is not a plain directory in home; skipped`, or the system's message) |

Sizes are `lpad(size, 9)`; `✓` green, `-` dim, `✗` red. Footer: when nothing was handled,
`Nothing was cleaned: no safe or review items matched.` (no chosen items) or `Nothing was cleaned.`;
otherwise a blank line and bold `Handled <size>` + ` in <n> item(s). Space is freed when you empty the Trash.`
Then, when a rule left out careful items, `Left out <n> careful item(s); name a candidate id to remove it:`
and one `  <size>  <safety>  <id>` row each.

Target **[Change] (#8)**: the command row reads dim `  ran: <argv> (permanent)`; the `Handled` line is
replaced by up to two lines, each only when non-zero:

```
Moved 3.1 MB to the Trash (1 item). Space is freed when you empty the Trash.
Removed 2.0 GB permanently with the tools' own commands (2 items).
```

When at least one row failed, a final red line `<n> item(s) failed.` and exit 3 **[Change] (#12)** (today
exit 2). The snapshot is saved before cleaning, as today.

### 6.4 `clean --json` schema

**[Change] (#9)**. Same encoding as `list --json` (pretty, sorted keys). Printed once at the end, for both
dry run and `--yes`; no human rows. Exit status as in section 7 (3 still applies).

```json
{
  "dryRun" : false,
  "home" : "\/Users\/me",
  "items" : [
    {
      "argv" : null,
      "bytes" : 3145728,
      "error" : null,
      "id" : "app-caches:Library\/Caches\/com.example.app",
      "outcome" : "trashed",
      "path" : "\/Users\/me\/Library\/Caches\/com.example.app",
      "removal" : "trash",
      "rule" : "app-caches",
      "safety" : "safe",
      "trashPath" : "\/Users\/me\/.Trash\/com.example.app"
    }
  ],
  "leftOut" : [ ],
  "totals" : { "commandBytes" : 0, "failed" : 0, "handled" : 1, "trashBytes" : 3145728 }
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `dryRun` | boolean | true without `--yes` |
| `home` | string | Absolute home |
| `items` | array of object | Chosen candidates in selection order |
| `items[].id`, `rule`, `path`, `bytes`, `safety`, `removal` | as in `list --json` | |
| `items[].argv` | array of string or null | The command for a command removal, else null |
| `items[].outcome` | string | Dry run: `planned` (Trash or command) or `info-only`. `--yes`: `trashed`, `ran`, `shared` (same argv already ran), `nothing` (info only), `failed` |
| `items[].trashPath` | string or null | Where the item landed in the Trash (`trashed` only) |
| `items[].error` | string or null | Reason (`failed` only), same text as the human row |
| `leftOut` | array of object | Careful candidates of a named rule that were not chosen; fields `id`, `rule`, `path`, `bytes`, `safety` |
| `totals.trashBytes` | integer | Bytes of `trashed` items (dry run: planned Trash items) |
| `totals.commandBytes` | integer | Bytes of `ran`/`shared` items (dry run: planned command items) |
| `totals.handled` | integer | Count of `trashed`/`ran`/`shared` items (dry run: `planned`) |
| `totals.failed` | integer | Count of `failed` items (0 in a dry run) |

Same compatibility rule as `list --json`.

### 6.5 Help text

**[Exists]** `main.swift:54-60`. **[Change] (#9, #12, #26)**:

```
Usage: fil clean <candidate-id|rule-id>... [--home DIR] [--yes] [--json] [--timings] [--no-color]

  --home DIR   use DIR instead of the home folder
  --yes        clean for real (default: dry run)
  --json       machine-readable output
  --timings    phase and rule timings on stderr
  --no-color   plain output (also when NO_COLOR is set or stdout is not a terminal)

A rule id selects its safe and review items; name a careful item by its candidate id. Most items move to
the Trash; some rules run the tool's own removal command, which is permanent (shown as "would run:").

Exit status: 0 success, 1 error (nothing matches), 2 usage error, 3 one or more items failed.
```

`list` help gets `--timings` and `Exit status: 0 success, 1 error, 2 usage error.`

---

## 7. Exit status

| Code | Today **[Exists]** | Target |
| --- | --- | --- |
| 0 | Success; help; version; doctor granted | Same |
| 1 | `fail()`: clean without selectors, `nothing matches`, `--home` without value; doctor denied or unknown | Runtime error: thrown errors (#1), DIR/`--home` missing or not a directory (#11), `nothing matches`; doctor denied or unknown **[Change] (#1, #11, #12)** |
| 2 | Usage errors (missing/unknown command, unknown option, missing value) **and** a partly failed `clean --yes` | Usage errors only: also invalid number, second DIR, option not valid for the command, clean without selectors, `--home` without value, `--naive --porcelain`, unknown completion shell **[Change] (#9, #10, #12)** |
| 3 | — | `clean --yes`: one or more items failed (others may have succeeded) **[Change] (#12)** |
| 133 | Any uncaught Swift error (e.g. `fil scan /nonexistent/x`) | Never **[Change] (#1)** |

Per command (target): `scan` 0/1/2; `doctor` 0/1/2; `list` 0/1/2; `clean` 0/1/2/3; `help`, `--version` 0/2;
`completion` 0/2.

---

## 8. Completions and man page

**[Change] (#27)**.

`fil completion zsh|bash|fish` prints the script for that shell on stdout, exit 0. Missing or other shell:
usage error `completion needs one of: zsh, bash, fish`, exit 2. The script completes:

- commands `scan doctor list clean completion help`, and `help <command>`;
- per command, exactly the options of sections 3-6, with `DIR`/`--home` completing directories only;
- `clean` positional arguments: the 12 rule ids from `Rules.all`, embedded when the script is generated.
  Candidate ids are not completed: getting them needs a scan of the home folder, too slow for a Tab press;
- `completion <shell>`: the three shell names.

Man page `fil.1` (mdoc), sections NAME, SYNOPSIS, DESCRIPTION, COMMANDS (the help texts of sections 2-6),
OUTPUT (porcelain fields of 3.4), EXIT STATUS (section 7), ENVIRONMENT (`NO_COLOR`, `TERM`,
`FIL_SNAPSHOT_DIR`), FILES (section 9), SEE ALSO `du(1)`.

`scripts/release.sh` generates the three completion files with the built binary and adds them and `fil.1` to
the tarball as `completions/_fil`, `completions/fil.bash`, `completions/fil.fish`, `man/fil.1`. The cask
installs them with its `zsh_completion`, `bash_completion`, `fish_completion` and `manpage` stanzas.

---

## 9. Where state lives

| What | Location | Written by | Status |
| --- | --- | --- | --- |
| Snapshots | `~/Library/Caches/com.vucod.Fil/snapshots/` (user caches directory), or `$FIL_SNAPSHOT_DIR` when set and non-empty | `scan` (not `--naive`), `list`, `clean --yes`; today also a dry-run `clean` | **[Exists]** `Snapshot.swift:14-29`; **[Change] (#13)** |
| Snapshot file name | `<FNV-1a 64 of the root path, lowercase hex, no padding>.bin`, one file per root path | | **[Exists]** `Snapshot.swift:15-20` |
| Tool path cache | `tool-paths.json` in the same directory | `list`/`clean` against the real home, when a tool's answer changed; not a dry run after #13 | **[Exists]** `Tools.swift:224-231` |

- **[Exists]** A snapshot is binary, magic `MTZ1`, format version 5; another version is ignored and
  replaced by a full scan. Saves are atomic (`Data.write(.atomic)`); an unchanged tree only gets its event
  id and scan start rewritten in place (`Snapshot.advance`, one 16-byte `pwrite`).
- **[Exists]** The key is the root path only, not `--private`: a `--private` scan and a normal scan of the
  same folder share one file and each replaces the other, so alternating them always does a full scan.
- **[Change] (#11)** The key is the `realpath` of the root, so `.`, relative paths and symlinks map to one
  snapshot per real folder.
- Nothing else is written: no config file, no log. `FIL_SNAPSHOT_DIR` is meant for tests and is documented
  only in the man page.

---

## 10. README and help parity

**[Change] (#26)** The help texts in `main.swift` and `Permissions.swift` are the source. README "Usage"
lists every command and option they list, plus an "Exit status" section copied from section 7. A CI check
(`scripts/check-help.sh`) fails when an option shown by `fil <cmd> --help` is missing from README.

Gaps today, all fixed by the change:

- README omits `--naive`, `--tolerant-hardlinks`, `--home DIR`, `-V`, `--timings`, and any exit status
  except doctor's.
- README: "Output is styled (colour, size bars, live progress on stderr) only on a terminal; it is plain
  when piped or when `NO_COLOR` is set." Code: size bars are always printed; `NO_COLOR` does not hide the
  progress line (it follows stderr being a TTY). Fix the README wording; the code stays.
- README: "`--porcelain` output never changes." Help and code: fields are appended over time, and
  `uncertain` sits mid-line. README takes the rule of 3.4.
- README: "`fil scan` lists the folders it could not read." Code lists at most 5 and `… and N more`.
- README: doctor "exit 0 = granted, 1 = missing". Code also exits 1 when the result is unknown.
- README safety model: "Fil never deletes files" and "`fil clean` … touches nothing". Code: command rules
  remove permanently (#8) and a dry run writes the snapshot (#13). After the changes the second is true;
  the first is reworded to "Fil never deletes files itself; a few rules run the tool's own removal command,
  which is permanent and marked as such."

---

## As built

- #11: DIR and `--home` (and the default home) go through `resolveDirectory` (`realpath`, then `stat`, must be a
  directory) after option parsing, so usage errors still come first. Error messages quote the argument as typed
  (`fil: <arg>: not a directory`); the header, the snapshot key and `home` in `--json` use the resolved path.
  `--naive` resolves the same way. Several DIRs: still the last one wins until #10.

## Glossary additions

- **Porcelain line**: the single `key=value` line of `fil scan --porcelain`; fields are only appended.
- **Responsible app**: the outermost `.app` nearest to launchd in fil's process ancestry; macOS grants it
  Full Disk Access on fil's behalf.
- **Unreadable folder**: a folder the scan could not open; kinds: privacy-protected (fixed by Full Disk
  Access), owned by another user, no permission.
- **Candidate id**: `<rule>:<path relative to home>` (or `<rule>:<key>`); names one cleanup candidate.
- **Selector**: a `clean` argument; a candidate id or a rule id.
- **Left-out item**: a `careful` candidate of a rule named by rule id; it is cleaned only when named by its
  own id.
- **Info-only candidate**: shown with its size but nothing can be done for it (the Trash).
- **Command removal**: a candidate removed by running the tool's own command; permanent, not via the Trash.
- **Dry run**: `fil clean` without `--yes`; reads, prints, writes nothing.
- **Usage error**: a malformed command line; exit 2.
- **Partial failure**: `clean --yes` where at least one item failed; exit 3.
- **Tool path cache**: `tool-paths.json`, cache locations reported by tools such as npm and pip, reused
  between runs.
