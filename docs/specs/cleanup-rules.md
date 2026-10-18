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
the set of running apps' bundle ids. Rules run in the order below; a path claimed by an earlier rule is
not reported again by a later one (Homebrew's cache is reported by its rule, not again under generic caches).

## Rules (MVP)

| id | What | Detection | Safety | Removal |
|---|---|---|---|---|
| `xcode-derived` | Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` | safe | trash |
| `xcode-device-support` | iOS/watchOS DeviceSupport | `~/Library/Developer/Xcode/*DeviceSupport/*` | review | trash |
| `simulators-unavailable` | Simulators for runtimes no longer installed | `xcrun simctl list devices unavailable -j` → `~/Library/Developer/CoreSimulator/Devices/<UDID>` sizes | safe | command `xcrun simctl delete <UDID>` (one per candidate) |
| `xcode-archives` | Xcode Archives | `~/Library/Developer/Xcode/Archives/*` | careful | trash |
| `homebrew-cache` | Homebrew downloads | `~/Library/Caches/Homebrew` | safe | trash (`brew cleanup` would also remove old installed versions outside home) |
| `pkg-caches` | npm, Cargo, Gradle, CocoaPods caches | `~/.npm/_cacache`, `~/.cargo/registry/cache`, `~/.gradle/caches`, `~/Library/Caches/CocoaPods` | review | trash |
| `project-artifacts` | Build output and dependencies inside projects | dir named `node_modules` (sibling `package.json`), `target` (`Cargo.toml`), `.build` (`Package.swift`), `Pods` (`Podfile`), `.venv`/`venv` (contains `pyvenv.cfg`); top-most match only; note = days since the manifest's mtime | review | trash |
| `app-caches` | Other apps' caches | each child of `~/Library/Caches` not claimed above | safe; review + note "app is running" when the folder name is a running app's bundle id; review + note "macOS component" for `com.apple.*` (e.g. `com.apple.bird` is iCloud's) | trash |
| `logs` | Logs | each child of `~/Library/Logs` | safe | trash |
| `trash` | Items already in the Trash | `~/.Trash` | — | none (info: "Empty the Trash in Finder") |

Every candidate path must exist, be inside the home directory, be on the home volume, and not be a
symlink. Skip candidates under 1 MB. Commands run through swift-subprocess
(https://github.com/swiftlang/swift-subprocess, pin an exact released version); a missing tool (`brew`,
`xcrun`) means the rule reports nothing.

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

UI, permanent deletion, Time Machine local snapshots, Docker/OrbStack, iOS backups, large/old files in
Downloads, scheduled cleaning.
