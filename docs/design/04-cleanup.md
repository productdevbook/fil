# 04 Cleanup

What Fil offers to remove, how big each item is, how safe it is to remove, and how it is removed.
This chapter supersedes `docs/specs/cleanup-rules.md`. Every statement of that spec was checked against
`Sources/CleanCore/*.swift` and `Sources/fil/Cleanup.swift`; where they differed, this chapter follows the
code and says so ("Spec said ...").

Status tags: **[Exists]** is in the code (file:line), **[Change]** is in the code and changes here (reason and
issue), **[New]** does not exist yet.

## 1. Goal and scope

- **[Exists]** Fil tells the user what can be removed, how many bytes each item takes and how safe removal is.
  Every size of an item inside home comes from the scan engine's `DiskTree` (`totalAlloc`, on-disk allocated
  bytes); no rule walks the disk again (`Model.swift:140`).
- **[Exists]** Items inside home are moved to the Trash (`Engine.swift:153-165`).
- **[Exists]** Items whose data a tool owns (simulators, simulator runtimes, Go caches, Docker) are removed
  by that tool's own command. These removals are permanent (see §7.3 and #8).

## 2. Module layout

- **[Exists]** Library target `CleanCore` depends on `ScanCore`. The `fil` executable (`list`, `clean`)
  depends on `CleanCore` (`Sources/fil/Cleanup.swift`).
- **[Exists]** `ScanCore` provides `DiskTree.node(at path: String) -> Int?`: absolute path inside `rootPath`
  to directory node id, walking components from the root through per-node child lists that are synced
  lazily under a lock (`DiskTree.swift:491`). Spec said "a child-name lookup built once on first use".
- **[Exists]** `fil list` and `fil clean` get the tree as `fil scan` does: `Snapshot.load`, then
  `Incremental.update`; a full `Scanner.scan(home)` when there is no usable snapshot; then `Snapshot.save`
  (or `Snapshot.advance` when no events arrived). Hard links are counted tolerantly
  (`ScanOptions(strictHardlinks: false)`) (`Cleanup.swift:38-62`).
- **[Exists]** Source files: `Model.swift` (types, `RuleContext`), `Rules.swift` (the rules),
  `Engine.swift` (scan, resolve, execute), `Selection.swift` (interactive selection model), `Tools.swift`
  (tool environment, locator, cache-path discovery, `tool-paths.json`), `Commands.swift` (runners),
  `Simctl.swift`, `Docker.swift`.

## 3. Model

### 3.1 Safety

**[Exists]** `public enum Safety: String, Sendable, Comparable { case safe, review, careful }`
(`Model.swift:4-8`). Order: `safe < review < careful`. Raw value is the JSON/CLI string.

| Safety | Meaning | Initial selection | Selected by rule id |
|---|---|---|---|
| `safe` | Regenerated automatically, holds no user data. | checked | yes |
| `review` | Rebuildable or re-downloadable, but costs time or bandwidth. | unchecked | yes |
| `careful` | May be the only copy of something (archives, custom cache locations). | unchecked, needs confirmation | no, only by candidate id |

### 3.2 Removal

**[Exists]** `public enum Removal: Sendable, Equatable { case trash, command(argv: [String]), none }`
(`Model.swift:10-14`).

| Removal | What happens | Recoverable |
|---|---|---|
| `trash` | `FileManager.trashItem` on the candidate path, after the re-check of §7.2. | yes, from the Trash |
| `command(argv:)` | `argv` runs without a shell; `argv[0]` is absolute. | **no** |
| `none` | Information only; nothing runs. | n/a |

### 3.3 Candidate

**[Exists]** (`Model.swift:41-66`)

| Field | Type | Meaning |
|---|---|---|
| `id` | `String` | Stable id, see §3.4. |
| `ruleId` | `String` | Id of the rule that produced it. |
| `path` | `String` | Absolute path; for Docker a label (`docker:build-cache`); for a runtime its `path` or, when empty, its identifier. |
| `bytes` | `Int64` | Tree candidates: `DiskTree` `totalAlloc` of the node. External: the tool's figure. |
| `safety` | `Safety` | §3.1. |
| `note` | `CandidateNote?` | §3.5. Spec said `String?`. |
| `removal` | `Removal` | §3.2. Init default `.trash`. |
| `isActionable` | `Bool` (computed) | False when `removal == .none`. |

**[Change]** (#3) New stored field `fileID: FileID?` with `public struct FileID: Sendable, Equatable { let dev:
dev_t; let ino: ino_t }`, filled by `RuleContext.make` from the `lstat` it already performs
(`Model.swift:144-145`). Nil for external candidates (`makeExternal`). Init parameter `fileID: FileID? = nil`.
Used by the trash re-check (§7.2).

### 3.4 Ids

- **[Exists]** Tree candidates: `"<rule id>:<path relative to home>"`, e.g.
  `xcode-derived:Library/Developer/Xcode/DerivedData/App-abc` (`Model.swift:149`).
- **[Exists]** External candidates: `"<rule id>:<key>"` (`Model.swift:158`):
  - `simulator-runtimes:<platform>-<version>-<build>`, e.g. `simulator-runtimes:tvOS-27.0-24J360`
    (`Simctl.swift:26`). `platform` is the first `-`-separated part of the last `.`-separated part of
    `runtimeIdentifier` (`xrOS` stays `xrOS` in the id; the display name says `visionOS`). Missing
    `version` or `build` becomes `?`.
  - `docker:build-cache`, `docker:dangling-images`.
- **[Exists]** Rule ids, in run order: `xcode-derived`, `xcode-device-support`, `simulators-unavailable`,
  `simulator-runtimes`, `xcode-archives`, `homebrew-cache`, `pkg-caches`, `project-artifacts`, `app-caches`,
  `logs`, `docker`, `trash` (`Rules.swift:6-79`).

### 3.5 CandidateNote

**[Exists]** `public enum CandidateNote` (`Model.swift:17-39`). The CLI prints `description`.

| Case | `description` | Used by |
|---|---|---|
| `appRunning` | `app is running` | `app-caches` |
| `macOSComponent` | `macOS component` | `app-caches` |
| `emptyTrashInFinder` | `Empty the Trash in Finder` | `trash` |
| `projectArtifact(kind:daysSinceManifest:)` | `<kind>, manifest untouched <n> days` | `project-artifacts` |
| `simulatorRuntime(name:)` | `<name>, no simulator uses it` | `simulator-runtimes` |
| `dockerEstimate` | `size reported by Docker; its disk image shrinks later` | `docker` |
| **[Change]** (#2) `customCacheLocation(tool:)` | `<tool> keeps its cache in a non-default folder` | `homebrew-cache`, `pkg-caches` |

Spec said the project note is "untouched 143 days" and the Docker note "the Docker disk image shrinks later".

### 3.6 Rule and RuleContext

- **[Exists]** `public struct Rule { id, title, explanation; func candidates(_ ctx: RuleContext) async ->
  [Candidate] }` (`Model.swift:68-75`). `explanation` is one sentence a non-developer understands. Spec said
  `candidates` is synchronous; it is `async` because tool answers are awaited.
- **[Exists]** `RuleContext` (`Model.swift:78-161`) holds:
  - `home`: the tree's `rootPath` (not the string passed to `scan`) (`Engine.swift:60`);
  - `tree`, a child index built once from the tree (dead nodes skipped);
  - `runningBundleIds`: bundle ids of `NSWorkspace.shared.runningApplications`, read once when the scan of
    rules starts (`Engine.swift:59`);
  - `isRealHome`: `realpath(home) == realpath(NSHomeDirectory())` (`Engine.swift:31-33`);
  - `tools`: the `ToolQueries` started before the tree was loaded (§5.3);
  - `skippedCommands: [String]`, the claim sets (§4.2), and `homeDev` (`stat(home).st_dev`, falling back to
    `tree.rootDev`).

### 3.7 Scan result

**[Exists]** `Cleanup.Scan { home, candidates, skippedCommands, ruleTimes }` (`Engine.swift:23-29`).
`candidates` are sorted by `bytes`, largest first, across all rules. `ruleTimes` is seconds per rule in run
order (`fil list --timings` prints it). `skippedCommands` order: the "not the real home" reason (if any),
then cache-path notes (sorted), simulator notes, Docker notes (`Engine.swift:62-73`).

## 4. Common candidate checks

### 4.1 Tree candidates (`RuleContext.make`)

**[Exists]** (`Model.swift:137-151`) A tree node becomes a candidate only when all hold, in this order:

1. `totalAlloc >= 1 MiB` (`1 << 20` = 1,048,576 bytes). Spec said "1 MB".
2. Its path starts with `home + "/"`.
3. It is not claimed and has no claimed ancestor (§4.2).
4. Unless `removal == .none`: it is not an ancestor of a claimed candidate (§4.2).
5. `lstat(path)` succeeds, it is a **directory** (`S_IFDIR`; a symlink or a file fails), and `st_dev ==
   homeDev`. Spec said "exist, not be a symlink"; the code requires a plain directory.

Then the path is claimed and every ancestor below home is added to `claimedAncestors`.

Because `DiskTree` holds directories only, a loose file (e.g. `~/Library/Logs/foo.log`) is never a candidate.

### 4.2 Claims

- **[Exists]** Rules run in the order of §3.4. A path claimed by an earlier rule, or any path below it, is not
  reported again (`isClaimed`, `Model.swift:126-134`). Example: `~/Library/Caches/Homebrew` is reported by
  `homebrew-cache`, not again by `app-caches`.
- **[Exists]** A folder that contains a claimed candidate is not reported as a removable candidate itself
  (`claimedAncestors`, `Model.swift:89,143`). Example: Yarn reports `~/Library/Caches/Yarn/v6`, so
  `~/Library/Caches/Yarn` is not an `app-caches` candidate.
- **[Exists]** The info-only `trash` candidate is exempt from rule 4.1.4 (`Model.swift:142-143`).

### 4.3 External candidates (`RuleContext.makeExternal`)

**[Exists]** (`Model.swift:155-160`) `simulator-runtimes` and `docker`: data lives outside the home tree.
Only check: `bytes >= 1 MiB`. No path check, no claim. `bytes` is the tool's own figure.

## 5. Tools

### 5.1 Running a query

**[Exists]** `SystemCommandRunner.run(_ argv:, timeout:)` (`Commands.swift:22-82`):

- swift-subprocess, absolute `argv[0]`, argv array, never a shell string.
- Child in its own session (`createSession = true`); teardown = SIGKILL to the process group, no grace.
- Working directory: home (so no project-local config is picked up).
- `PATH` = `<dir of argv[0]>:<dir of realpath(argv[0])>:<inherited PATH or /usr/bin:/bin>` (npm, pnpm,
  yarn are `#!/usr/bin/env node` scripts).
- Quiet environment (`Commands.swift:27-31`), added to the inherited one:

  | Variable | Value |
  |---|---|
  | `HOMEBREW_NO_AUTO_UPDATE` | `1` |
  | `HOMEBREW_NO_ANALYTICS` | `1` (spec did not list it) |
  | `NO_UPDATE_NOTIFIER` | `1` |
  | `npm_config_update_notifier` | `false` |
  | `COREPACK_ENABLE_NETWORK` | `0` |
  | `COREPACK_ENABLE_DOWNLOAD_PROMPT` | `0` |
  | `PIP_DISABLE_PIP_VERSION_CHECK` | `1` |
  | `GOTOOLCHAIN` | `local` |

- Output limits: stdout 16 MiB, stderr 1 MiB.
- Timeout: `ToolEnvironment.timeout`, default **3 s** per query (`Tools.swift:20`). A timer task races the
  command; the first to finish wins, cancelling the other kills the child's process group.
- Result `CommandResult`: `.success(stdout)` (exit 0), `.failed(reason)` (non-zero exit, signal or launch
  error; reason = termination status + first stderr line, at most 200 chars), `.timedOut`.
- `CommandRunner` is a protocol; tests inject a fake and never need real tools.

### 5.2 Finding binaries

**[Exists]** `ToolLocator.find` (`Tools.swift:51-75`): first executable match in
`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/Library/pnpm`, `~/.docker/bin`,
`~/.orbstack/bin`, `/usr/bin`, `/bin`. `/usr/bin/pip3` is a stub that may open the "install command line
tools" dialog; it is used only when `/Library/Developer/CommandLineTools/usr/bin/pip3` or
`/Applications/Xcode.app/Contents/Developer/usr/bin/pip3` is executable.

### 5.3 When queries run

- **[Exists]** `Cleanup.startToolQueries(home:)` starts three tasks concurrently, before the tree is loaded,
  so they overlap snapshot load and incremental update: cache paths, simulators (two queries, concurrent),
  Docker (`Engine.swift:44-47`, `Tools.swift:92-97`). The CLI calls it through the older name
  `startSimulatorQuery(home:)` (`Cleanup.swift:40`, `Engine.swift:50`).
- **[Exists]** `--home` that is not the real home: no tool runs. `skippedCommands` gets
  `external commands (not the real home)`; cache rules use their default paths resolved against `--home`
  (except Go, §6.7); command-only rules report nothing (`Tools.swift:93`).

### 5.4 Failure behaviour

**[Exists]** Nothing a tool does fails the scan.

| Situation | Effect | `skippedCommands` line |
|---|---|---|
| Tool not found | default location / no candidates | none |
| Cache query fails, times out, or prints something unparsable | default location | `<tool> <args>: <reason>; using the default location` |
| simctl devices query fails | no simulator candidates at all | `xcrun simctl list devices -j: <reason>` |
| simctl runtime query fails | unavailable simulators kept, no runtimes | `xcrun simctl runtime list -j: <reason>` |
| Docker non-zero exit (daemon not running) | no Docker candidates | none |
| Docker timeout | no Docker candidates | `docker system df -v --format json: timed out after 3 s` |
| Docker unparsable output | no Docker candidates | `docker system df -v --format json: unexpected output` |

`<reason>` for a timeout is `timed out after 3 s`. The tool name is the basename of `argv[0]`. Spec's
example `...; using ~/.npm` is wrong: the code says `using the default location`. Spec said a failing simctl
query yields no candidates; a failing **runtime** query keeps the unavailable simulators (`Simctl.swift:75-96`).

## 6. Rules, in run order

| # | id | Title | Safety | Removal |
|---|---|---|---|---|
| 1 | `xcode-derived` | Xcode build data | safe | trash |
| 2 | `xcode-device-support` | Xcode device support files | review | trash |
| 3 | `simulators-unavailable` | Unavailable simulators | safe | command |
| 4 | `simulator-runtimes` | Unused simulator runtimes | review | command |
| 5 | `xcode-archives` | Xcode archives | careful | trash |
| 6 | `homebrew-cache` | Homebrew downloads | safe (careful if custom, #2) | trash |
| 7 | `pkg-caches` | Developer package caches | review (careful if custom, #2) | trash; Go: command |
| 8 | `project-artifacts` | Project build output and dependencies | review | trash |
| 9 | `app-caches` | App caches | safe / review | trash |
| 10 | `logs` | Logs | safe | trash |
| 11 | `docker` | Docker build cache and dangling images | review | command |
| 12 | `trash` | Trash | review | none |

**[Exists]** Spec listed `xcode-archives` before `simulator-runtimes`; the code runs runtimes first
(`Rules.swift:24-33`). The order only matters for claims, and runtimes claim nothing.

### 6.1 `xcode-derived`

- **[Exists]** (`Rules.swift:7-12`) Detection: each child of `~/Library/Developer/Xcode/DerivedData`.
- Safety `safe`. Removal `trash`. Explanation: "Temporary files Xcode creates while building apps; it
  recreates them when needed."

### 6.2 `xcode-device-support`

- **[Exists]** (`Rules.swift:13-19`) Detection: each child of every child of `~/Library/Developer/Xcode`
  whose name ends with `DeviceSupport` (e.g. `iOS DeviceSupport/<version>`, `watchOS DeviceSupport/<version>`).
- Safety `review` (re-copied from the device on next connection, which is slow). Removal `trash`.

### 6.3 `simulators-unavailable`

- **[Exists]** (`Rules.swift:158-168`, `Simctl.swift:42-54`) Detection: `xcrun simctl list devices -j`;
  every device with `isAvailable == false` (JSON bool) and a `udid` string. Candidate: the node
  `~/Library/Developer/CoreSimulator/Devices/<UDID>`, checked by §4.1. A UDID without a tree node yields
  nothing.
- Safety `safe`. Removal `command [<xcrun>, "simctl", "delete", <UDID>]`, one per candidate. `<xcrun>` is
  the located binary (normally `/usr/bin/xcrun`).

### 6.4 `simulator-runtimes`

- **[Exists]** (`Rules.swift:170-177`, `Simctl.swift`) Purpose: runtimes (iOS, watchOS, tvOS, visionOS)
  take 3 to 8 GB each and stay after the last simulator using them is deleted.
- Detection: `xcrun simctl runtime list -j` (object keyed by identifier; fields `identifier`,
  `runtimeIdentifier`, `version`, `build`, `sizeBytes`, `deletable`, `state`, `path`) and the device list of
  §6.3 (`devices` keyed by `runtimeIdentifier`). A runtime is a candidate when:
  - no device, available or not, is listed under its `runtimeIdentifier` (a key with an empty list counts as
    unused);
  - `deletable` is not `false` (missing counts as deletable);
  - `runtimeIdentifier` is present and `sizeBytes` is a number > 0.
  `state` is not read. Runtimes are sorted by `runtimeIdentifier`, then `build`.
- Without a parsable device list, no runtime is reported (cannot know which are used).
- Id: §3.4. Path: the runtime's `path`, or its `identifier` when `path` is empty. Note
  `simulatorRuntime(name: "<platform> <version> (<build>)")`, `xrOS` shown as `visionOS`.
- Size: `sizeBytes` from the JSON (runtimes live in `/System/Library/AssetsV2` or
  `/Library/Developer/CoreSimulator`, outside the tree). §4.3 applies.
- Safety `review` (Xcode downloads it again, several GB). Removal `command [<xcrun>, "simctl", "runtime",
  "delete", <identifier>]`.

### 6.5 `xcode-archives`

- **[Exists]** (`Rules.swift:28-33`) Detection: each child of `~/Library/Developer/Xcode/Archives` (the
  date folders, e.g. `Archives/2026-10-01`).
- Safety `careful`: an archive may be the only copy needed to symbolicate or re-submit a release.
  Removal `trash`.

### 6.6 `homebrew-cache`

- **[Exists]** (`Rules.swift:34-39`) Detection: tool-reported location of `brew --cache` (§6.7 table and
  rules), fallback `~/Library/Caches/Homebrew`.
- Safety `safe`. Removal `trash`. Not `brew cleanup`: that also removes old installed versions outside home.
- **[Change]** (#2) Safety `careful` with note `customCacheLocation(tool: "brew")` when the location is
  custom (§6.7.3).

### 6.7 `pkg-caches`

**[Exists]** (`Rules.swift:40-50,130-156`, `Tools.swift:135-218`) Purpose: report caches where the tool
actually keeps them (custom `HOMEBREW_CACHE`, `GOMODCACHE`, `npm_config_cache`, ...).

Candidates, in this order: the tool-reported locations of npm, pnpm, yarn, go, pip3, uv, then the fixed paths
`~/.cargo/registry/cache`, `~/.gradle/caches`, `~/Library/Caches/CocoaPods`. Safety `review`. Removal
`trash`, except Go.

#### 6.7.1 Tool table

| Tool name | Query argv | Candidate | Default (relative to home) | Config files (mtime in key) | Env vars (value in key) |
|---|---|---|---|---|---|
| `brew` | `brew --cache` | reported dir | `Library/Caches/Homebrew` | `.homebrew/brew.env` | `HOMEBREW_CACHE`, `XDG_CACHE_HOME` |
| `npm` | `npm config get cache` | `<reported>/_cacache` (logs and `_npx` stay) | `.npm` → `.npm/_cacache` | `.npmrc` | `npm_config_cache`, `NPM_CONFIG_CACHE` |
| `pnpm` | `pnpm store path` | reported dir | `Library/pnpm/store` | `Library/Preferences/pnpm/rc`, `.npmrc` | `PNPM_HOME`, `npm_config_store_dir`, `XDG_DATA_HOME` |
| `yarn` | `yarn cache dir` | reported dir | `Library/Caches/Yarn` | `.yarnrc`, `.yarnrc.yml` | `YARN_CACHE_FOLDER`, `XDG_CACHE_HOME` |
| `go` | `go env GOMODCACHE GOCACHE` | both lines | `go/pkg/mod`, `Library/Caches/go-build` (not used, see 6.7.4) | `Library/Application Support/go/env` | `GOPATH`, `GOMODCACHE`, `GOCACHE`, `GOENV` |
| `pip3` | `pip3 cache dir` | reported dir | `Library/Caches/pip` | `.config/pip/pip.conf`, `Library/Application Support/pip/pip.conf`, `.pip/pip.conf` | `PIP_CACHE_DIR`, `PIP_CONFIG_FILE`, `XDG_CACHE_HOME` |
| `uv` | `uv cache dir` | reported dir | `.cache/uv` | `.config/uv/uv.toml` | `UV_CACHE_DIR`, `XDG_CACHE_HOME` |

Spec named pip `pip` in places; the tool name (and `tool-paths.json` key) is `pip3`.

#### 6.7.2 Parsing and location checks

- **[Exists]** Parse (`Tools.swift:168-173`): stdout split on newlines, each line trimmed, empty lines
  dropped. Valid only when the number of lines equals the number of defaults (1, Go: 2) and every line starts
  with `/`. Paths are standardized (`URL.standardized`). Anything else (empty, relative, `undefined`) is a
  failure. Spec did not mention the exact line count.
- **[Exists]** Duplicate paths within one rule are reported once (`Rules.swift:134,145`).
- **[Exists]** Shared-location check (`Rules.swift:123-128,152-156`), on `realpath` of both the path and
  home. The location is ignored when it is home, an ancestor of home, or exactly one of:
  `Library`, `Library/Caches`, `Library/Application Support`, `Library/Developer`, `Library/Containers`,
  `Library/Group Containers`, `Library/Mobile Documents`, `Library/CloudStorage`, `Library/Preferences`,
  `Library/Logs`, `Documents`, `Desktop`, `Downloads`, `Movies`, `Music`, `Pictures`, `Public`,
  `Applications`, `.cache`, `.config`, `.local`, `.local/share`, `.local/state`, `.Trash`, `go`, `go/pkg`.
  Spec listed six of these followed by "...".
- **[Exists]** Tree lookup (`Model.swift:111-116`): a path that starts with `home + "/"` is looked up as
  given; only a path that does not is resolved with `realpath` and mapped back below home. A path outside home
  yields nothing (the tree covers home only). Then §4.1 applies. Spec said "matched as reported and, if
  needed, after resolving symlinks"; the code resolves only when the text is not under home.
- **[Change]** (#2) The exact-match list only blocks a fixed set; `PIP_CACHE_DIR=~/Projects` or
  `HOMEBREW_CACHE=~/Developer` passes and the whole folder becomes a candidate. New rule, applied in
  `cacheLocations` to every tool-reported candidate path (live or from `tool-paths.json`), after the
  shared-location check and before the tree lookup. Let `R` be the candidate path relative to the resolved
  home (after `realpath`, after the npm `_cacache` subpath), split into components:
  0. **Default:** a path equal to or below the tool's resolved default (§6.7.3) is accepted as is, without 1 and 2
     (so `Library/pnpm/store/v10` and `go/pkg/mod` pass). `GOMODCACHE=~/go/src` and `~/Developer/store` are
     refused: a bare `go` or `store` component is not a marker.
  1. **Depth:** `R` has at least 2 components. `~/Projects` and `~/Developer` fail; `~/.cache/uv` passes.
  2. **Marker:** the last component of `R` matches (when it is only a version, `v<digits>` or digits, the one
     before it counts too; a marker in a higher ancestor such as `~/cache-backup/Projects` does not count), case-insensitively, one of:
     - the generic substring `cache` (matches `Caches`, `.cache`, `_cacache`, `cache`);
     - the tool's markers:

       | Tool | Substring markers | Exact-component markers |
       |---|---|---|
       | `brew` | `homebrew` | |
       | `npm` | `npm` | `_cacache` |
       | `pnpm` | `pnpm` | |
       | `yarn` | `yarn` | |
       | `go` | `go-build`, `gomod` | |
       | `pip3` | `pip` | |
       | `uv` | | `uv` |

  A path that fails 1 or 2 is ignored and adds the `skippedCommands` line
  `<tool>: reported cache ~/<R> does not look like a cache folder; ignored`. Go's two paths are checked
  separately; if either fails, neither Go candidate is reported (`go clean` removes the whole directory Go
  names, so a wrong `GOMODCACHE` must never reach a command). The default paths of §6.7.1 all pass.
  Why not stricter: real custom locations such as `~/.cache/pip` or `/Volumes/...` (ignored anyway as
  outside home) must keep working; depth + marker blocks a plain project or document folder.

#### 6.7.3 Custom locations are careful

- **[Change]** (#2) A tool-reported candidate is **custom** when its resolved path is neither equal to nor
  below the resolved default candidate path of the same tool and line (§6.7.1). Below counts as default
  because Yarn and pnpm report a versioned subfolder (`Library/Caches/Yarn/v6`, `Library/pnpm/store/v10`).
  A custom candidate gets safety `careful` and note `customCacheLocation(tool:)`, in both `homebrew-cache`
  and `pkg-caches`, for trash and command removals. The fixed Cargo, Gradle and CocoaPods paths and default
  fallbacks are never custom. The code cannot tell an env var from a config file; both move the cache and
  both are treated the same.
- Effect: a rule id (`fil clean pkg-caches`) no longer removes a custom location; it must be named by its
  candidate id, and the dry run lists it as left out (§8).

#### 6.7.4 Go

- **[Exists]** (`Rules.swift:139-141`) The module cache is read-only on disk (0444 files, 0555 dirs), so a
  Trash copy cannot be emptied cleanly. Both Go caches are removed by Go: line 1 (`GOMODCACHE`) by
  `[<go>, "clean", "-modcache"]`, line 2 (`GOCACHE`) by `[<go>, "clean", "-cache"]`. `<go>` is the binary
  located now (`reportedBy["go"]`), which matches the one that answered because the binary's resolved path
  and mtime are part of the cache key.
- Reported only when `go` named them (live or from `tool-paths.json`) and gave exactly 2 paths. With `go`
  missing or failing, or `--home` not the real home, neither is reported, and `~/Library/Caches/go-build` is
  an ordinary `app-caches` folder.

#### 6.7.5 `tool-paths.json`

**[Exists]** (`Tools.swift:220-271`) npm and pip take about 1 s to start, so successful answers are cached.

- File: `tool-paths.json` in the snapshot directory: `$FIL_SNAPSHOT_DIR` if set and non-empty, else
  `~/Library/Caches/com.vucod.Fil/snapshots/`.
- Format: JSON object, tool name → `{ "key": String, "paths": [String] | null, "savedAt": Double }`
  (`savedAt` in seconds since 1970). `paths` are stored as parsed, **without** the npm subpath; the subpath
  is applied on read. `null` = the query failed.
- Key: `|`-joined: `realpath(binary)`, its mtime as `<sec>.<nsec>`, the query argv joined by spaces
  (`npm config get cache`), each config file as `<relative path>=<mtime or ->`, each env var as
  `<NAME>=<value or empty>`. Spec did not list the argv part.
- Freshness: `0 <= now - savedAt < 7 * 86,400 s` for a success, `< 86,400 s` for a failure. A fresh entry
  with matching key skips the query. A reused failure uses the defaults silently (no `skippedCommands` line).
- A timeout is not stored (the tool may just have been slow). A tool that is not found has its entry
  removed. The file is rewritten (atomically, directory created) only when entries changed.
- The cache only saves time: every path still goes through §6.7.2 and §4.1.

### 6.8 `project-artifacts`

**[Change] (F-038)** Matches under `~/.Trash` are skipped: those projects are already in the Trash and are
reported once by the info-only `trash` candidate. Closes the open question in "As built".

- **[Exists]** (`Rules.swift:85-114`) Detection: every live tree node in id order (a parent before its
  children), anywhere under home, named:

  | Directory | Required manifest | Where |
  |---|---|---|
  | `node_modules` | `package.json` | sibling |
  | `target` | `Cargo.toml` | sibling |
  | `.build` | `Package.swift` | sibling |
  | `Pods` | `Podfile` | sibling |
  | `.venv` | `pyvenv.cfg` | inside |
  | `venv` | `pyvenv.cfg` | inside |

  The manifest must pass `lstat`. Top-most match only: once a directory matches (even if §4.1 then rejects
  it, e.g. under 1 MiB or already claimed), nothing below it is examined.
- Note `projectArtifact(kind: <dir name>, daysSinceManifest: max(0, floor((now - manifest mtime) / 86,400)))`.
- Safety `review`. Removal `trash`.

### 6.9 `app-caches`

- **[Exists]** (`Rules.swift:55-64`) Detection: each child of `~/Library/Caches` not claimed and not holding a
  claimed candidate (§4.2).
- Safety and note:

  | Folder name | Safety | Note |
  |---|---|---|
  | equals a running app's bundle id | review | `appRunning` |
  | starts with `com.apple.` (e.g. `com.apple.bird`, iCloud) | review | `macOSComponent` |
  | otherwise | safe | none |

  A running Apple app gets `appRunning`. Running apps come from `NSWorkspace` once per scan.
- Removal `trash`.

### 6.10 `logs`

- **[Exists]** (`Rules.swift:65-68`) Detection: each child directory of `~/Library/Logs`. Safety `safe`.
  Removal `trash`.

### 6.11 `docker`

- **[Exists]** (`Docker.swift`, `Rules.swift:179-189`) Purpose: build cache and dangling images often take
  many GB inside the Docker VM disk image.
- Discovery: `docker` located (§5.2). If at least one engine app is installed at
  `/Applications/OrbStack.app` (`dev.kdrag0n.MacVirt`), `/Applications/Docker.app` (`com.docker.docker`) or
  `/Applications/Rancher Desktop.app` (`io.rancherdesktop.app`) and none of the installed ones is running,
  nothing is queried (connecting to the socket could start the VM). Otherwise
  `docker system df -v --format json`: one JSON object; it must contain `Images` or `BuildCache`.
- Sizes are strings like `52.51MB`, `1.396GB (100%)`, `0B`, `512kB`, `1.5GiB`: the text before `(` is
  number + unit; units `b`, `kb`, `mb`, `gb`, `tb`, `pb` are powers of 1000, `kib`, `mib`, `gib`, `tib` powers
  of 1024 (case-insensitive). Flags are `"true"`/`"false"` strings or bools; counts numbers or strings.
- Build cache bytes (what `docker builder prune -f` frees): sum of `Size` over `BuildCache` records with
  `InUse` false, `Shared` false (shared with an image: frees nothing) and `CacheType` present and not
  `internal`/`frontend` (kept without `--all`). Plain `docker system df` "Reclaimable" includes those and
  overstates.
- Dangling image bytes (what `docker image prune -f` frees): sum of `UniqueSize` over `Images` with
  `Repository == "<none>"`, `Tag == "<none>"` and `Containers == 0`. A record with an unparsable flag,
  count or size is skipped.
- Candidates (§4.3): `docker:build-cache` (path `docker:build-cache`, removal
  `[<docker>, "builder", "prune", "-f"]`) and `docker:dangling-images` (path `docker:dangling-images`,
  removal `[<docker>, "image", "prune", "-f"]`). Note `dockerEstimate`. Safety `review`.
- Never volumes, containers, unused-but-tagged images, never `--all`.

### 6.12 `trash`

- **[Exists]** (`Rules.swift:73-78`) Detection: `~/.Trash`, through §4.1 (so 1 MiB minimum, must be a
  directory on the home volume). Safety `review` (spec said "—"). Note `emptyTrashInFinder`. Removal `none`.
- Not counted in "Total removable" (`Cleanup.swift:103`).

## 7. Execution

`Cleanup.execute(_ items:, home:, trasher:) async -> [(Candidate, Outcome)]` (`Engine.swift:133-169`).
Items run one after another in the order given. One failure never stops the others.

### 7.1 Outcomes

**[Exists]** `Outcome`: `trashed(URL)` (where it landed), `commandRan`, `commandShared` (the same argv
already ran for an earlier item), `nothingToDo` (`removal == .none`), `failed(Failure)`. `Failure`:
`pathChanged` ("path changed or is not a plain directory in home; skipped"), `system(String)`.

- **[Exists]** Commands are deduplicated by exact argv: a later item with the same argv gets `commandShared`,
  or the same `failed` outcome if the first run failed.
- **[Change]** (#14) New `Failure.timedOut(seconds: Int)`, description
  `timed out after <n> s; the command was stopped`.
- **[Change]** (#3) New `Failure.movedOtherItem(URL)`, description
  `a different item was moved to the Trash at <path>; put it back`.

### 7.2 Trash re-check

- **[Exists]** Right before `trasher.trash` (`Engine.swift:153-160`): `path` starts with `home + "/"`,
  `lstat(path)` is a directory, and its `st_dev` equals `stat(home).st_dev`. Otherwise `failed(.pathChanged)`.
  The move is `FileManager.trashItem(at:resultingItemURL:)`, never `removeItem`, never unlink
  (`SystemTrasher`). `Trasher` is a protocol so tests never touch the real Trash.
- **[Change]** (#3) Only the last component is checked; a symlinked ancestor (e.g. `~/Library/Logs` → elsewhere)
  or an ancestor swapped between scan and move is not caught. Replacement, for every `.trash` item:
  1. `fileID` is non-nil and `path` starts with `home + "/"`; else `pathChanged`.
  2. `fd = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)` (home itself may be reached through a symlink);
     `fstat(fd).st_dev` is `homeDev`.
  3. For each component of `path` below home except the last:
     `fd = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`. Failure (`ELOOP`,
     `ENOTDIR`, `ENOENT`, ...) → `pathChanged`. Each opened ancestor's `st_dev` must equal `homeDev`.
  4. `fstatat(parentFd, last, &st, AT_SYMLINK_NOFOLLOW)`: must be `S_IFDIR`, `st.st_dev == fileID.dev ==
     homeDev`, `st.st_ino == fileID.ino`. Else `pathChanged`.
  5. Close all descriptors, then `trasher.trash(path)`.
  6. After the move, `lstat(resultingURL)`: `st_dev`/`st_ino` must equal `fileID` (a rename on the same
     volume keeps the inode; `~/.Trash` is on the home volume). Mismatch → `failed(.movedOtherItem(url))`,
     so the user can put back what was moved by mistake.
  The window between step 4 and `trashItem` (path-based API) remains; steps 1-4 shrink it to microseconds
  and step 6 detects it.
- Command items get no path re-check: the tool owns the data and checks its own identifiers.

### 7.3 Commands

- **[Exists]** `Commands.output(argv, workingDirectory: home)` (`Commands.swift:93-108`): swift-subprocess,
  no shell, working directory home, the quiet environment of §5.1 (so `go clean` neither reads a project's
  `go.mod` nor downloads a toolchain), stdout 16 MiB / stderr 1 MiB. Non-zero exit →
  `failed(.system("<basename> failed: <status> <stderr>"))`. Unlike queries: no `PATH` prefix, no session,
  no timeout.
- **[Change]** (#14) A hung `docker` or `simctl` blocks `fil clean --yes` forever, and Ctrl-C may leave the
  child running. Removal commands go through the same `CommandRunner` as queries:
  - `execute` gains `runner: any CommandRunner = SystemCommandRunner(workingDirectory: home,
    gracePeriod: .seconds(5))` and `removalTimeout: Duration = .seconds(600)`.
  - Same platform options as queries: own session (`createSession = true`), quiet environment and `PATH`
    prefix. Teardown for removals: SIGTERM to the process group, wait 5 s (`gracePeriod`), then SIGKILL to the
    group. Queries keep `gracePeriod = .zero` (immediate SIGKILL).
  - Timeout **600 s per command**. Why: the slowest real removals are `go clean -modcache` on a large module
    cache (hundreds of thousands of read-only files, a few minutes on APFS), `docker builder prune` of tens of
    GB inside the VM, and `simctl runtime delete` of an 8 GB image (under a minute). 10 minutes is several
    times the slowest seen, so a working command is never cut off, and a hang is bounded. `.timedOut` →
    `failed(.timedOut(seconds: 600))`; the next items still run.
  - Ctrl-C: the child is in its own session and no longer gets the terminal's SIGINT. `fil clean` installs a
    SIGINT handler (`DispatchSource.makeSignalSource`) that cancels the execute task; cancellation runs the
    teardown above; the CLI then prints what was done so far and exits 130.
  - `.failed(reason)` → `failed(.system("<basename> failed: <reason>"))`.

## 8. Selection

### 8.1 Command line (`Cleanup.resolve`)

**[Exists]** (`Engine.swift:114-130`) For each selector, in order:

1. Candidates whose `id` equals it (careful included).
2. If none: the rule's candidates whose `ruleId` equals it, minus `careful` ones, which go to `leftOut`. A
   rule whose candidates are all careful selects nothing and does not throw.
3. If neither matched: throw `NoMatch` ("nothing matches '<selector>'"); the CLI prints it and exits 1.

`chosen` keeps first-seen order without duplicate ids. The info-only `trash` candidate can be chosen; it
yields `nothingToDo`.

### 8.2 Interactive selection model (`CleanupSelection`)

**[Exists]** (`Selection.swift`) UI-free state of a checkbox list:

- `update(candidates:)`: keeps choices of ids still present, drops vanished ids, checks a candidate only the
  first time it is seen and only if `safe` and actionable. A candidate that vanished and came back counts as
  new.
- `set(_:to:confirmed:)`: unchecking always applies; checking a non-actionable item → `ignored`; checking a
  `careful` item without `confirmed: true` → `needsConfirmation` (nothing changes).
- Group state: `unavailable` (no actionable items), `off`, `on` (all actionable checked), `mixed`.
- `toggleGroup`: if every actionable non-careful item is checked, clear the whole group (careful too);
  otherwise check all actionable non-careful items. Careful items are never checked in bulk.
- `selected(in:)`, `totalBytes(in:)`: over the given list only.

## 9. CLI

```
fil list  [--home DIR] [--json] [--timings] [--no-color]
fil clean <candidate-id|rule-id>... [--home DIR] [--yes] [--timings] [--no-color]
```

- **[Exists]** `--home DIR` (standardized) makes Fil testable on a fixture: every rule path resolves against
  it; tools are skipped unless it is the real home (§5.3). Unknown options exit 2 with the help text.
- **[Exists]** `fil list`: per rule (in rule order, skipping empty ones) title, total, item count, rule id,
  explanation, then each candidate (size, safety, `~` path, note) with `id <id> -> <removal>`; then one
  `Skipped: <line>` per `skippedCommands` entry; then `Total removable` (excluding info-only) and elapsed time.
  `--json`: `{ "home", "candidates": [{ "id", "rule", "path", "bytes", "safety", "note" (string or null),
  "removal" ("trash", "info only", or argv joined by spaces) }] }`, sorted keys.
- **[Exists]** `fil clean` without `--yes` is a dry run and changes nothing. With `--yes` each outcome prints
  one line (`✓`, `-`, `✗ failed: <reason>`); careful items a rule id left out are listed afterwards with
  "name a candidate id to remove it"; exit 2 if any item failed. `clean` without selectors exits 1.
- **[Change]** (#8) Command removals are permanent, but the dry run says "Would move to the Trash"
  (`Cleanup.swift:116`) and the summary "Space is freed when you empty the Trash" (`:158`). New wording:
  - Dry-run header: `Would clean  <~home>`.
  - Per item target: trash → `-> move to the Trash`; command → `-> would run: <argv>`; none →
    `-> info only`. `<argv>` is the arguments joined by single spaces, `argv[0]` in full; an argument
    containing a space or any of `'"\$`;&|<>()*?[]#~` is wrapped in single quotes (display only; never run
    through a shell).
  - Left-out careful items: unchanged (`not selected, name its id to remove`).
  - Footer, each line only when non-zero:
    `Would move <X> to the Trash; space is freed when the Trash is emptied.`
    `Would permanently remove <Y> by running <n> command(s); this cannot be undone from the Trash.`
    then `Dry run, nothing changed; add --yes to do it.`
  - After `--yes`: `Moved <X> to the Trash in <n> item(s). Space is freed when you empty the Trash.` and
    `Removed <Y> permanently in <m> item(s) by running the tools' own commands.` (each only when non-zero).
    `commandShared` items count toward `<Y>`.
  - `fil list` footer: `Clean items with: fil clean <id|rule> --yes (trash items go to the Trash; command
    items are removed permanently)`.
  - README "Safety model": replace "Fil never deletes files" with: items inside your home folder are moved
    to the Trash; the rules `simulators-unavailable`, `simulator-runtimes`, Go caches in `pkg-caches` and
    `docker` run the tool's own removal command, which is not recoverable from the Trash; the dry run shows
    `would run: <argv>` for those.

## 10. What is NOT cleaned

- **[Exists]** Files outside home, except through `simctl` (runtimes) and `docker` (inside its VM).
- **[Exists]** Loose files: only directories are candidates (§4.1).
- **[Exists]** Anything under 1 MiB, symlinks, items on another volume than home.
- **[Exists]** Docker volumes, containers, tagged images, `--all` prunes.
- **[Exists]** Old Homebrew versions (`brew cleanup`), npm logs and `_npx`.
- **[Exists]** The Trash itself: shown, never emptied ("Empty the Trash in Finder").
- **[Exists]** A tool cache whose location is home, an ancestor of home, a shared folder (§6.7.2), outside
  home, or (with #2) fails depth/marker.
- **[Exists]** Go caches when `go` did not name them.
- **[Exists]** Out of scope: permanent deletion of user data, Time Machine local snapshots, iOS backups,
  large or old files in Downloads, scheduled cleaning.
- **[Exists]** Known gap, no issue yet: `project-artifacts` scans all of home including `~/.Trash`, so a
  `node_modules` already in the Trash (with its `package.json`) is reported again as a removable candidate.
  Open question: skip the `.Trash` subtree in that rule.

## 11. Tests

**[Exists]** `Tests/CleanCoreTests/CleanCoreTests.swift` (fixture home, sizes vs `du -sk × 1024`, resolve,
execute, last-component re-check at `:256-276`), `ToolTests.swift` (parse, fallback, path cache, locator,
timeouts, concurrency, simctl, Docker), `SelectionTests.swift`.

**[Change]** (#21) Add:

| Test | File | Covers |
|---|---|---|
| env-overridden cache path (`PIP_CACHE_DIR=~/Projects`) is ignored with a note; `~/.cache/pip` custom is `careful` with `customCacheLocation`; Yarn `v6` below default stays `review` | `ToolTests.swift` | #2, §6.7.2-3 |
| a bad `GOMODCACHE` drops both Go candidates | `ToolTests.swift` | #2 |
| trash re-check: symlinked ancestor; directory replaced (same path, new inode); `fileID.dev` mismatch; `fileID` nil | `CleanCoreTests.swift` | #3, §7.2 |
| a removal command that fails, and one that hangs (fake runner, `removalTimeout: .seconds(1)`), the next item still runs | `CleanCoreTests.swift` | #14, §7.3 |
| `app-caches` with a running bundle id → `review` + `appRunning` | `CleanCoreTests.swift` | §6.9 |
| `.venv`/`venv` (`pyvenv.cfg` inside), `Pods` (`Podfile`), `.build` (`Package.swift`) | `CleanCoreTests.swift` | §6.8 |
| `clean` dry run vs `--yes` output, incl. `would run:` and both footers | `Tests/FilTests` | #8, §9 |
| `list --json` schema | `Tests/FilTests` | §9 |
| argument parsing and exit codes; `NO_COLOR` / `--no-color` / non-TTY output | `Tests/FilTests` | CLI (#21) |

**[Change]** (#50) The concurrency test ("queries run concurrently: three hanging tools cost one timeout, not
three", `ToolTests.swift:445-460`) never runs a hanging tool. It locates every tool at `/bin/sleep`, so each query
is `/bin/sleep --cache` and the like, which exits at once with a usage error: the test takes about 30 ms locally
and would pass with the queries run one after another. On CI the process launches alone took 1.77 s against the
old 1.5 s bound; commit `8687439` widened it to 2.5 s with a 1 s timeout to unblock v0.2.0. Reason for the change:
the test must prove §5.3's claim that hanging tools cost one timeout, not one each.

- The fake tool is a script the test writes into the fixture (`#!/bin/sh` then `exec /bin/sleep 60`, mode 755)
  and `locate` returns for every tool name. It ignores its arguments and sleeps far longer than the timeout; the
  process-group SIGKILL of §5.1 ends it.
- `CacheTools.discover` runs all seven cache queries (`brew`, `npm`, `pnpm`, `yarn`, `go`, `pip3`, `uv`) with
  timeout `T` = 1 s. Run one after another they take at least 7 × `T`.
- Checks: every one of the seven tools has a note ending `timed out after 1 s; using the default location`;
  elapsed ≥ `T` (the tools really hung); elapsed < 3.5 s (half the serial minimum, so a slow runner has 2.5 s of
  launch overhead before the test fails, and serial queries can never pass); defaults are used as before.
- The test name says seven tools, not three.

## As built

## Glossary additions

- `Safety`: `safe`, `review`, `careful`.
- `Removal`: `trash`, `command(argv:)`, `none`.
- Candidate id: `<rule id>:<path relative to home>`; external: `simulator-runtimes:<platform>-<version>-<build>`,
  `docker:build-cache`, `docker:dangling-images`.
- Rule ids: `xcode-derived`, `xcode-device-support`, `simulators-unavailable`, `simulator-runtimes`,
  `xcode-archives`, `homebrew-cache`, `pkg-caches`, `project-artifacts`, `app-caches`, `logs`, `docker`,
  `trash`.
- `CandidateNote` cases: `appRunning`, `macOSComponent`, `emptyTrashInFinder`, `projectArtifact`,
  `simulatorRuntime`, `dockerEstimate`, `customCacheLocation` (new, #2).
- `skippedCommands`: one line per tool that was skipped, failed or timed out.
- Claim, claimed ancestor: §4.2.
- Tree candidate / external candidate: §4.1 / §4.3.
- Tool names (cache key): `brew`, `npm`, `pnpm`, `yarn`, `go`, `pip3`, `uv`.
- `tool-paths.json`: the tool-path cache, §6.7.5.
- Custom cache location: §6.7.3 (#2).
- `FileID` (`dev`, `ino`) on `Candidate` (new, #3).
- `Outcome`: `trashed`, `commandRan`, `commandShared`, `nothingToDo`, `failed`; `Failure`: `pathChanged`,
  `system`, `timedOut` (new, #14), `movedOtherItem` (new, #3).
- Query timeout 3 s; removal timeout 600 s with 5 s grace (#14).
- `CleanupSelection`, `GroupSelectionState` (`on`, `off`, `mixed`, `unavailable`).
