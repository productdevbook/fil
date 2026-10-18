# Cleanup rules (step 2)

Goal: tell the user what can be removed, how much space each item takes and how safe it is, using the
scan engine's `DiskTree` for every size (no extra walks). Removal moves items to the Trash.

## Module layout

- New library target `CleanCore` (depends on `ScanCore`), the `fil list` and `fil clean` commands (depends on `CleanCore`).
- `ScanCore` gains `DiskTree.node(at path: String) -> Int?` (walks components from the root through a
  child-name lookup built once on first use).
- Sizes come from `DiskTree` totals of the scanned home directory. `fil list` gets the tree the same way `fil scan`
  does: snapshot + incremental update, full scan if needed.

## Model

```swift
enum Safety { case safe, review, careful }
// safe:    regenerated automatically, holds no user data. Preselected.
// review:  rebuildable or re-downloadable, but costs time or bandwidth. Not preselected.
// careful: may be the only copy of something (archives, backups). Never preselected, shown with a warning.

struct Candidate {
    let id: String          // stable: "<rule id>:<path relative to home>"
    let ruleId: String
    let path: String
    let bytes: Int64        // on-disk (alloc) total from DiskTree
    let safety: Safety
    let note: String?       // e.g. "untouched 143 days", "app is running"
    let removal: Removal
}
enum Removal { case trash, command(argv: [String]), none }   // none = information only
```

A rule is a value with `id`, `title`, `explanation` (one sentence a non-developer understands), and
`func candidates(_ ctx: RuleContext) -> [Candidate]`. `RuleContext` holds the home path, the `DiskTree`, and
the set of running apps' bundle ids, and the tool queries started before the tree was loaded. Rules run in the order below; a path claimed by an earlier rule is
not reported again by a later one (Homebrew's cache is reported by its rule, not again under generic caches).

## Rules (MVP)

| id | What | Detection | Safety | Removal |
|---|---|---|---|---|
| `xcode-derived` | Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` | safe | trash |
| `xcode-device-support` | iOS/watchOS DeviceSupport | `~/Library/Developer/Xcode/*DeviceSupport/*` | review | trash |
| `simulators-unavailable` | Simulators for runtimes no longer installed | `xcrun simctl list devices -j`, devices with `isAvailable == false` → `~/Library/Developer/CoreSimulator/Devices/<UDID>` sizes | safe | command `xcrun simctl delete <UDID>` (one per candidate) |
| `xcode-archives` | Xcode Archives | `~/Library/Developer/Xcode/Archives/*` | careful | trash |
| `simulator-runtimes` | Simulator runtimes no device uses | `xcrun simctl runtime list -j` minus the runtimes named in `xcrun simctl list devices -j` (see below) | review | command `xcrun simctl runtime delete <identifier>` |
| `homebrew-cache` | Homebrew downloads | `brew --cache` (fallback `~/Library/Caches/Homebrew`) | safe | trash (`brew cleanup` would also remove old installed versions outside home) |
| `pkg-caches` | Package manager caches | tool-reported locations (see below), plus `~/.cargo/registry/cache`, `~/.gradle/caches`, `~/Library/Caches/CocoaPods` | review | trash; Go: command `go clean -modcache` / `go clean -cache` |
| `project-artifacts` | Build output and dependencies inside projects | dir named `node_modules` (sibling `package.json`), `target` (`Cargo.toml`), `.build` (`Package.swift`), `Pods` (`Podfile`), `.venv`/`venv` (contains `pyvenv.cfg`); top-most match only; note = days since the manifest's mtime | review | trash |
| `app-caches` | Other apps' caches | each child of `~/Library/Caches` not claimed above | safe; review + note "app is running" when the folder name is a running app's bundle id; review + note "macOS component" for `com.apple.*` (e.g. `com.apple.bird` is iCloud's) | trash |
| `logs` | Logs | each child of `~/Library/Logs` | safe | trash |
| `docker` | Docker build cache and dangling images | `docker system df -v --format json` (see below) | review | command `docker builder prune -f` / `docker image prune -f` |
| `trash` | Items already in the Trash | `~/.Trash` | — | none (info: "Empty the Trash in Finder") |

Every candidate path (except the command-only rules `simulator-runtimes` and `docker`, whose data lives
outside home) must exist, be inside the home directory, be on the home volume, and not be a
symlink. Skip candidates under 1 MB. Commands run through swift-subprocess
(https://github.com/swiftlang/swift-subprocess, pin an exact released version); a missing tool (`brew`,
`xcrun`) means the rule reports nothing.

## Asking tools (step 3)

Where a tool owns its data or decides where it lives, the rules ask the tool instead of guessing paths.

Running a tool:

- Through swift-subprocess with an absolute path and an argv array; never a shell string. The child runs in
  its own session (process group) with the home directory as working directory (so a project's local
  config is not picked up), the tool's own directory first in `PATH` (npm, pnpm and yarn are node scripts),
  and `HOMEBREW_NO_AUTO_UPDATE=1`, `NO_UPDATE_NOTIFIER=1`, `npm_config_update_notifier=false`,
  `COREPACK_ENABLE_NETWORK=0`, `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`, `PIP_DISABLE_PIP_VERSION_CHECK=1`,
  `GOTOOLCHAIN=local` (a query never downloads anything).
- Every query has a 3 s timeout; on timeout the whole process group is killed (SIGKILL).
- All queries start together, concurrently, before the tree is loaded (`Cleanup.startToolQueries`), so
  they overlap the snapshot load and incremental update.
- Binaries are found without a shell, first match wins: `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin`, `~/.cargo/bin`, `~/Library/pnpm`, `~/.docker/bin`, `~/.orbstack/bin`, `/usr/bin`, `/bin`.
  `/usr/bin/pip3` is a developer-tools stub that may open the "install command line tools" dialog; it is
  used only when Xcode or the Command Line Tools provide the real `pip3`.
- Commands are an injectable `CommandRunner` (tests use a fake; no test needs the real tools).
- `--home` that is not the real home: no tool runs; cache rules use the default paths below, resolved
  against `--home`; command-only rules report nothing.
- Failure behaviour: a missing tool, non-zero exit, unparsable output or timeout never fails the scan. A
  missing tool is silent; a failure or timeout adds one line to `skippedCommands` (e.g. `npm config get
  cache: timed out after 3 s; using ~/.npm`). The rule then uses its fallback or reports nothing.

### Tool-reported cache locations (`homebrew-cache`, `pkg-caches`)

Purpose: report the caches where the tool actually keeps them (custom `HOMEBREW_CACHE`, `GOMODCACHE`,
`npm_config_cache`, ...), not only where they are by default.

| Tool | Query | Candidate | Fallback (tool missing or failed) |
|---|---|---|---|
| Homebrew | `brew --cache` | the reported dir | `~/Library/Caches/Homebrew` |
| npm | `npm config get cache` | `<reported>/_cacache` (logs and `_npx` stay) | `~/.npm/_cacache` |
| pnpm | `pnpm store path` | the reported store dir | `~/Library/pnpm/store` |
| Yarn | `yarn cache dir` | the reported dir | `~/Library/Caches/Yarn` |
| Go | `go env GOMODCACHE GOCACHE` | both reported dirs (one per line) | none (see Removal) |
| pip | `pip3 cache dir` | the reported dir | `~/Library/Caches/pip` |
| uv | `uv cache dir` | the reported dir | `~/.cache/uv` |

- Discovery: the query's stdout, trimmed, one absolute path per line; anything else (empty, relative,
  `undefined`) counts as a failure. A reported path outside home is ignored (the tree covers home only).
  A reported path that is home, an ancestor of home, or a folder shared by many apps (`~/Library`,
  `~/Library/Caches`, `~/Library/Application Support`, `~/Documents`, `~/.cache`, `~/.config`, ...) is
  ignored: trashing it would take other apps' data along.
- Size: from the `DiskTree` node of the path, like every other trash candidate (no extra walk). Paths are
  matched as reported and, if needed, after resolving symlinks.
- Removal: Trash, except Go. Safety: `homebrew-cache` safe; the rest review (re-download costs time).
- Go: the module cache is read-only on disk (0444 files, 0555 dirs, Go's own protection), so a Trash copy
  cannot be emptied cleanly. Both Go caches are removed by Go itself: GOMODCACHE by command
  `go clean -modcache`, GOCACHE by `go clean -cache` (the `go` that answered the query). They are reported
  only when `go` named them (live or from `tool-paths.json`); with `go` missing or failing, the module cache
  is not reported and `go-build` is an ordinary `app-caches` folder.
- Removal commands (all rules) run with the home directory as working directory and the quiet
  environment above (`GOTOOLCHAIN=local`: `go clean` never downloads a toolchain).
- Claims: these run before `app-caches`, so `~/Library/Caches/pip`, `go-build`, `Yarn` are reported under
  `pkg-caches`, not again as app caches. A folder that contains a claimed candidate is never reported as a
  removable candidate itself (Yarn reports `~/Library/Caches/Yarn/v6`, so `~/Library/Caches/Yarn` is not an
  app cache); the info-only `trash` candidate is exempt.
- Speed: npm and pip take about 1 s to start. Successful answers are cached in
  `<snapshot dir>/tool-paths.json`, keyed by the binary's resolved path and mtime, the tool's config files'
  mtimes and the environment variables that move the cache; an entry is reused for 7 days (a failure for
  1 day). The cache only saves time: every path is still checked against the tree and the disk.

### Simulator runtimes (`simulator-runtimes`)

Purpose: simulator runtimes (iOS, watchOS, tvOS, visionOS) take 3 to 8 GB each and stay installed after
the last simulator using them is deleted.

- Discovery: `xcrun simctl runtime list -j` (object keyed by identifier; fields `identifier`,
  `runtimeIdentifier`, `version`, `build`, `sizeBytes`, `deletable`, `state`, `path`) and
  `xcrun simctl list devices -j` (`devices` keyed by `runtimeIdentifier`). A runtime is a candidate when no
  device (available or not) is listed under its `runtimeIdentifier`, `deletable` is not false and
  `sizeBytes` > 0. The same device query also yields `simulators-unavailable` (`isAvailable == false`).
- Id: `simulator-runtimes:<platform>-<version>-<build>` (e.g. `simulator-runtimes:tvOS-27.0-24J360`); path:
  the runtime's `path`; note: `.simulatorRuntime(name:)` ("tvOS 27.0 (24J360), no simulator uses it").
- Size: `sizeBytes` from the JSON; runtimes live outside home (`/System/Library/AssetsV2`,
  `/Library/Developer/CoreSimulator`), so the tree cannot size them.
- Removal: command `xcrun simctl runtime delete <identifier>` (simctl owns these images). Safety: review
  (Xcode downloads a runtime again when a new simulator needs it, several GB).
- Failure: `xcrun` missing or a query failing → no candidates (plus a `skippedCommands` line on failure).

### Docker (`docker`)

Purpose: Docker's build cache and dangling images often take many GB inside the Docker VM disk image.

- Discovery: `docker` found on disk; if a known engine app (OrbStack, Docker Desktop, Rancher Desktop) is
  installed and none of them is running, nothing is queried (talking to the socket could start the VM).
  Otherwise `docker system df -v --format json` (one JSON object with `Images` and `BuildCache` arrays;
  sizes are human-readable strings such as `52.51MB`, decimal units; flags are `"true"`/`"false"`).
- Candidates: `docker:build-cache` (removal `docker builder prune -f`) and `docker:dangling-images`
  (removal `docker image prune -f`). Never volumes, never containers, never unused-but-tagged images, never
  `--all`. Path is a label (`docker:build-cache`), not a file. Note: `.dockerEstimate` ("size reported by
  Docker; the Docker disk image shrinks later").
- Size: exactly what each command frees, from Docker's own figures (bytes inside the VM, not part of the
  home tree). Build cache: `Size` of records with `InUse` false, `Shared` false (shared with an image: frees
  nothing) and `CacheType` not `internal`/`frontend` (`builder prune` without `--all` keeps those); the
  Build Cache `Reclaimable` of plain `docker system df` includes them and would overstate. Dangling images:
  `UniqueSize` of `<none>:<none>` images with `Containers` 0 (`image prune` keeps images a container uses;
  `Size` would count layers other images keep).
- Safety: review.
- Failure: daemon not running (non-zero exit) → no candidates and no message. Timeout or unparsable
  output → no candidates, one `skippedCommands` line.

## Removal

- Trash: `FileManager.trashItem(at:resultingItemURL:)`. Never `removeItem`, never unlink.
- After removing, report bytes moved per candidate and remind that space is freed when the Trash is emptied.
- One failing candidate does not stop the others; failures are listed with the error.

## CLI

```
fil list  [--home DIR] [--json]        # categories with totals, then candidates sorted by size
fil clean <candidate-id|rule-id>... [--home DIR] [--yes]
```
`clean` without `--yes` is a dry run that prints what would happen. A rule id selects that rule's `safe` and
`review` candidates only; a `careful` candidate is removed only when named by its candidate id, and the
dry run lists any careful items a rule id left out. `--home` makes the tool testable on a
fixture directory: every rule path is resolved against it, and commands are skipped when `--home` is not
the real home.

## Out of scope for this step

UI, permanent deletion, Time Machine local snapshots, Docker volumes and containers, iOS backups, large/old files in
Downloads, scheduled cleaning.
