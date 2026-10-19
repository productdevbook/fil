# 06. Map layout (MapCore)

MapCore is a public treemap layout library. It turns one folder of a scanned tree, plus the level below it,
into a list of rectangles (a two-level squarified treemap). It is pure geometry: no drawing, no UI framework,
no file system access. Whoever draws the rectangles (and localizes their labels) lives outside this package.

Status tags: **[Exists]** is in the code today (file reference given), **[Change]** is a required change
(reason and issue given), **[New]** is something that does not exist yet.

## 1. Place in the package

- **[Exists]** Target `MapCore`, path `Sources/MapCore`, two files: `Squarify.swift` (the algorithm) and
  `MapLayout.swift` (protocol, tile model, two-level layout). `Package.swift`:
  `.target(name: "MapCore", dependencies: ["CleanCore"])`, exported as `.library(name: "MapCore", targets: ["MapCore"])`.
- **[Exists]** The only reason for the `CleanCore` dependency is the `Safety` enum (`safe`, `review`, `careful`)
  used to colour tiles. MapCore imports `CleanCore`, `CoreGraphics` (`CGRect`, `CGSize`, `CGFloat`) and `Foundation`
  (`ByteCountFormatter`). `Squarify.swift` imports only `CoreGraphics`.
- **[Exists]** No type in this repository conforms to `MapSource` except the test fake `FakeTree`
  (`Tests/MapCoreTests/LayoutTests.swift:7`). `ScanCore.DiskTree` stores the needed numbers
  (`totalAlloc`, `ownAlloc`, `totalCloneAware`, `ownCloneAware`, `name`, `parent` in `DirNode`,
  `Sources/ScanCore/DiskTree.swift:5-29`) but has no `children(of:)` index, and the `fil` CLI does not use MapCore.
  A `DiskTree` conformance is out of scope for this chapter.
- **[Change]** The doc comment on `MapSource` (`MapLayout.swift:5`) names a conforming type that does not exist in
  this repository. Reword it to: `/// What the layout needs to know about a scanned tree. Tests use an in-memory fake.`
  The comment in `Package.swift` ("Disk Map geometry: squarified treemap and the two-level layout. No UI.") stays.
  Reason: CLAUDE.md, the repository is public and describes only what it contains. Done together with #19.

## 2. Coordinate system

- **[Exists]** Rectangles are in the caller's points, origin at the top-left of `size`, y growing downward
  (a "row on top" is placed at `free.minY`, `Squarify.swift:45-53`; the header strip of a folder is at the top,
  `MapLayout.swift:121`). A caller with a y-up coordinate system must flip.
- **[Exists]** Values are `Double` inside `squarify`, rectangles are `CGRect` (`CGFloat` = `Double` on arm64).

## 3. `squarify(values:in:)` (`Sources/MapCore/Squarify.swift`)

Signature **[Exists]**: `public func squarify(values: [Double], in rect: CGRect) -> [CGRect]`.
Algorithm: Bruls, Huizing, van Wijk, "Squarified Treemaps" (2000). Pure function.

Contract **[Exists]** (`Squarify.swift:3-9`):

- Input `values` are non-negative and sorted largest first. The order is a precondition, not checked.
- Output has exactly `values.count` rectangles, in input order.
- Area of rectangle `k` = `values[k] / sum(values) * rect.width * rect.height` (up to floating-point error).
- The rectangles tile `rect` exactly: no gaps, no overlap (edges touch).
- Zero values, an all-zero input, an empty input, or a frame with zero width or height give `.zero`
  rectangles (`CGRect.zero`), never a crash.

Steps **[Exists]** (line numbers in `Squarify.swift`):

1. `out` = `n` copies of `.zero`; `sum` = sum of values. Return `out` unless `n > 0`, `sum > 0`,
   `rect.width > 0` and `rect.height > 0` (lines 11-14).
2. `scale = rect.width * rect.height / sum`: converts a value to an area (line 15). `free = rect`, `i = 0`.
3. While `i < n` and `values[i] > 0` (line 18): start a new row.
   - `short = min(free.width, free.height)`: the row is laid along the shorter side of the free space.
   - Grow the row from `j = i`: candidate row sum `s = rowSum + values[j] * scale`; worst aspect ratio of the
     row with item `j` added is
     `w = max(short² · hi / s², s² / (short² · lo))`, where `hi = values[i] * scale` (largest item of the row,
     because input is sorted) and `lo = values[j] * scale` (smallest). If `w > worst`, stop (item `j` starts
     the next row); otherwise accept: `worst = w`, `rowSum = s`, `j += 1`. Growth also stops at the first
     zero value (lines 21-32). Equal ratio (`w == worst`) is accepted.
   - `last` = no positive value follows the row (`j >= n || values[j] <= 0`, line 33).
4. Place the row (lines 34-54):
   - If `free.width >= free.height`: a column at the left edge of `free`. Width = `free.width` when `last`,
     else `rowSum / free.height`. Items stacked top to bottom, each `values[k] * scale / width` high; the
     last item of the row takes the remainder `free.maxY - y` (absorbs rounding). `free` loses the column
     on its left.
   - Else: a row at the top of `free`. Height = `free.height` when `last`, else `rowSum / free.width`. Items
     left to right, each `values[k] * scale / height` wide; the last item takes `free.maxX - x`. `free` loses
     the row at its top.
   - `i = j`.
5. Items after the first zero value keep `.zero`.

Properties that follow from the code:

- **[Exists]** Exact tiling comes from the two "remainder" rules: the last row fills all remaining free space,
  the last item of each row fills the rest of the row.
- **[Exists]** Cost is O(n): each item is accepted once; at most one rejected evaluation per row.
- **[Exists]** If the precondition is broken (unsorted input), the result still tiles `rect` and areas stay
  proportional, but `hi` is not the row's maximum, so rectangles are less square. A zero in the middle of an
  unsorted input truncates the layout there: every later value gets `.zero`. Negative values are undefined
  behaviour of the contract (they reduce `sum`).

## 4. `MapSource` protocol (`Sources/MapCore/MapLayout.swift:6-17`)

**[Exists]** today:

| Requirement | Meaning |
|---|---|
| `func children(of id: Int32) -> ArraySlice<Int32>` | Subfolders of a folder. Documented as "largest first"; the layout re-sorts, so the order is not relied on. |
| `func totalAlloc(of id: Int32) -> Int64` | Allocated bytes of the folder including everything below it. |
| `func ownAlloc(of id: Int32) -> Int64` | Allocated bytes of the files directly inside the folder. |
| `func name(of id: Int32) -> String` | Folder name (one path component). |
| `func parent(of id: Int32) -> Int32?` | Parent folder; `nil` at the root. |
| `func safety(of id: Int32) -> Safety?` | Safety level of the cleanup candidate rooted exactly at this folder, if any. |

Folder ids are `Int32`, the same id space as `DiskTree` (`DirNode` index).

## 5. Tile model

**[Exists]** `public struct MapTile: Identifiable` (`MapLayout.swift:20-45`):

| Field | Meaning |
|---|---|
| `id: Int` | Position in `MapLayout.tiles` (0, 1, 2, ...). |
| `kind: Kind` | `.folder(Int32)`, `.files` (the files directly inside `owner`, as one rectangle), `.rest(count: Int)` (the `count` smallest items of `owner` merged into one rectangle). `Kind` is `Equatable`. |
| `owner: Int32` | The folder whose content this tile belongs to: the current folder for depth 0, the depth-0 folder for depth 1. For `.folder` tiles this is the parent, not the folder itself (the code comment at line 31 says "the tile's own folder for `.folder`"; the code at lines 118 and 130 sets the parent; the comment is wrong). |
| `rect: CGRect` | Position, see section 2. |
| `depth: Int` | 0 = current level, 1 = one level below. |
| `bytes: Int64` | Size the tile represents. |
| `name: String` | Folder name; empty for `.files` and `.rest`, whose text the caller localizes. |
| `safety: Safety?` | Colour class, see section 6.4. |
| `expanded: Bool` | Depth-0 folder tile with its children drawn inside it. Always `false` at depth 1. |
| `sizeText: String` | `bytes` formatted for display, or empty when the tile is too small for a label (depth 1 only). |
| `folder: Int32?` | Computed: the folder id for `.folder`, else `nil`. |

- **[Change]** Fix the `owner` doc comment to: `/// The folder whose content this tile belongs to (for a `.folder` tile, its parent).` Reason: the comment contradicts the code. Done with #19.

**[Exists]** `public struct MapLayout` (`MapLayout.swift:47-55`): `tiles: [MapTile]` (in drawing order: each
depth-0 tile is followed immediately by its depth-1 children) and `seconds: Double`.

## 6. Two-level layout: `MapLayouter.build` (`MapLayout.swift:57-137`)

Signature **[Exists]**: `public static func build<S: MapSource>(_ source: S, node: Int32, size: CGSize) -> MapLayout`.

### 6.1 Constants

| Constant | Value | Use |
|---|---|---|
| `MapLayouter.minSide` | `3` (points) | A rectangle narrower or lower than this is not emitted (depth 0 and depth 1). |
| `MapLayouter.maxItems` | `300` | Items laid out one by one per level; beyond this the tail is merged into one `.rest` tile. |
| `MapLayouter.headerHeight` | `16` (points) | Strip at the top of an expanded folder reserved for its name. |
| expand width (literal) | `60` | A depth-0 folder expands only if its rectangle is at least 60 wide ... |
| expand height (literal) | `40` | ... and at least 40 high (line 115). |
| inner inset (literal) | `1` | Children area = rectangle inset by 1 on left, right and bottom, and by `headerHeight` on top (line 121). |
| label width (literal) | `40` | A depth-1 tile gets `sizeText` only if at least 40 wide ... |
| label height (literal) | `14` | ... and at least 14 high (line 129). |

All three named constants are `public static let`; the five literals are not exposed.

### 6.2 Items of one folder (`items(_:of:)`, lines 72-89)

1. One `.folder(c)` item per child `c` with `totalAlloc(of: c) > 0`, bytes = `totalAlloc(of: c)`, name = `name(of: c)`.
   Empty folders are dropped.
2. One `.files` item if `ownAlloc(of: node) > 0`, name empty.
3. Sort by bytes, largest first.
4. If there are more than `maxItems` (300) items: the items from index 299 on (`count - 299` items) become one
   `.rest(count: count - 299)` item whose bytes are their sum; it replaces them and the list is sorted again.
   Result: exactly 300 items, of which 299 are individual. The `.files` item can end up inside `.rest`.

### 6.3 Steps of `build`

1. Return an empty `MapLayout()` if `size.width <= 0`, `size.height <= 0` or `totalAlloc(of: node) <= 0` (line 93).
2. Create one `ByteCountFormatter` with `countStyle = .file` (decimal units, as Finder) for all `sizeText`s.
3. Inherited safety: walk from `node` itself up through `parent(of:)`; the first non-`nil` `safety(of:)` is
   `inherited` (lines 99-104). Zooming into a candidate, or into any folder below one, colours everything.
4. `top = items(source, of: node)`; `topRects = squarify(values: top.bytes, in: CGRect(origin: .zero, size: size))`.
5. For each top item `i` with rectangle `r`:
   - Skip it if `r.width < 3 || r.height < 3`. Its area stays empty in the drawing (no tile, no merge into `.rest`).
   - `safety = inherited`; for a `.folder(f)`: `safety = source.safety(of: f) ?? inherited`.
   - For a `.folder(f)` with `r.width >= 60 && r.height >= 40`: `inner = items(source, of: f)`.
     `expanded = !inner.isEmpty`.
   - Append the depth-0 tile: `owner = node`, `sizeText` always filled.
   - If expanded: children area `CGRect(x: r.minX + 1, y: r.minY + 16, width: r.width - 2, height: r.height - 17)`.
     The guard `area.width > 3, area.height > 3` (line 122) can never fail, because expansion requires
     width >= 60 and height >= 40 (area at least 58 x 23).
   - `squarify(inner.bytes, in: area)`; for each child rectangle `cr`: skip if `cr.width < 3 || cr.height < 3`;
     safety = the child folder's own `safety(of:)` ?? the parent tile's `safety` (`.files` and `.rest` take the
     parent tile's); `sizeText` only if `cr.width >= 40 && cr.height >= 14`, else `""`; `name` always set for folders;
     `depth = 1`, `owner = f`, `expanded = false`.
6. Return `MapLayout(tiles: tiles)`. `seconds` stays `0`.

Consequences:

- **[Exists]** Depth-0 tiles tile the frame when no rectangle is skipped; skipped rectangles leave holes.
  `sum(depth-0 bytes) == totalAlloc(of: node)` only when nothing was skipped.
- **[Exists]** A folder is drawn at most two levels deep; zooming is the caller calling `build` again with a child id.
- **[Exists]** `totalAlloc(of:)` is called twice per child and `children(of:)` once per folder; with the
  300-item cap a build touches at most 1 + 300 folders' child lists.
- **[Exists]** Ties in `bytes` are ordered by Swift's `sort`, which is not documented as stable; equal-size items
  may swap places between builds of different inputs. Not observed as a problem; no change.

### 6.4 Safety colouring summary

| Tile | `safety` |
|---|---|
| depth-0 folder `f` | `safety(of: f) ?? inherited` |
| depth-0 `.files` / `.rest` | `inherited` |
| depth-1 folder `c` | `safety(of: c) ?? (parent tile's safety)` |
| depth-1 `.files` / `.rest` | parent tile's safety |

`inherited` = first non-nil `safety(of:)` on the path from `node` to the root, `node` included.

## 7. Tests that exist

`swift test --filter MapCoreTests` runs both suites. Target `MapCoreTests` depends on `MapCore` and `CleanCore`.

**[Exists]** `Tests/MapCoreTests/SquarifyTests.swift`, suite `"squarify"`. Inputs come from a deterministic
SplitMix64 generator (values in `1...1_000_000`, sorted descending), so failures reproduce. Frames:
`800x600 at (0,0)`, `300x900 at (10,20)`, `1000x40 at (0,0)`, `77x77 at (5,5)`.

| Test | Arguments | Checks |
|---|---|---|
| `proportional` | 4 frames x counts `[1, 2, 7, 60, 300]` (seed `count * 7919`) | `count` rects; each area within `max(1e-6 * frameArea, expected * 1e-6)` of `value / total * frameArea` |
| `tilesExactly` | 4 frames x `[1, 3, 25, 200]` (seed `count * 31`) | areas sum to the frame area within `1e-6` relative; every rect inside the frame within `1e-6` |
| `noOverlap` | 4 frames x `[2, 12, 80]` (seed `count * 101`) | largest pairwise intersection area `<= 1e-6 * frameArea` |
| `edgeCases` | none | `[]` gives `[]`; `[0, 0]` gives two `.zero`; `[5]` gives the frame; zero-width frame gives `.zero`s; `[4, 4, 0]` in 100x100 gives `.zero` third and area 5000 first |
| `aspectRatios` | none | `[600, 600, 400, 400, 200, 200]` in 600x400: every rect has aspect ratio `< 4` |

**[Exists]** `Tests/MapCoreTests/LayoutTests.swift`, suite `"Disk Map level layout"`, using `FakeTree`
(node 0 = root; `totalAlloc` computed recursively from `own`; `children` sorted by total). Sample tree:
`~` own 1,000,000; `Library` own 100 with `Caches` 6,000,000 (`safe`) and `Logs` 2,000,000; `proj` own 4,000,000
with `node_modules` 3,000,000 (`review`). Frame 800x600.

| Test | Checks |
|---|---|
| `topLevelFillsFrame` | 3 depth-0 tiles; their areas sum to 480,000 within 1; bytes descending |
| `kinds` | `.folder(1)` 8,000,100; `.folder(4)` 7,000,000; `.files` 1,000,000 with empty name; `Library` name |
| `childrenInsideParent` | every depth-1 tile lies inside its expanded depth-0 parent and below `headerHeight`; at least one depth-1 tile |
| `safetyColours` | `node_modules` `review`, `Caches` `safe`, `Logs` `nil`; built at node 5 every tile is `review` |
| `skipsTinyTiles` | 1,000,000,000 vs 10 bytes in 300x200: one depth-0 tile; no tile below `minSide` |
| `mergesTail` | 350 folders in 4000x3000: one `.rest` with `count == 51`; 300 depth-0 tiles; bytes sum to root total |
| `emptyInputs` | `.zero` size and an empty tree give no tiles |
| `idsAreSequential` | `tiles.map(\.id) == Array(tiles.indices)` |

Not covered today: depth-1 `.rest` tiles, `sizeText` emptiness below 40x14, the 60x40 expansion threshold,
and anything clone-related.

## 8. Clone-aware sizes and `seconds` (#19)

Reason: [02 · Size accounting](02-size-accounting.md) defines the clone-aware size (`cloneaware=`, each APFS full-clone family
counted once) as what is shown as "on disk" and used to rank the tree. `MapSource` only offers allocated sizes,
so a folder full of clones (`cp -c`, app bundles, simulators) is drawn at its inflated `du` size, larger than the
disk itself in extreme cases. And `MapLayout.seconds` is declared but never assigned.

### 8.1 Protocol change **[Change]** (#19)

Final `MapSource` (complete text; doc comments are part of the contract):

```swift
/// What the layout needs to know about a scanned tree. Tests use an in-memory fake.
public protocol MapSource {
    /// Subfolders of a folder, in any order; the layout sorts them.
    func children(of id: Int32) -> ArraySlice<Int32>
    /// Allocated bytes of a folder including everything below it (hard links once): what `du -skx` reports.
    func totalAlloc(of id: Int32) -> Int64
    /// Allocated bytes of the files directly inside a folder.
    func ownAlloc(of id: Int32) -> Int64
    /// Clone-aware bytes of a folder including everything below it: like `totalAlloc`, but each APFS
    /// full-clone family counted once, in the folder that owns it (docs/design/02-size-accounting.md).
    func totalCloneAware(of id: Int32) -> Int64
    /// Clone-aware bytes of the files directly inside a folder.
    func ownCloneAware(of id: Int32) -> Int64
    func name(of id: Int32) -> String
    func parent(of id: Int32) -> Int32?
    /// Safety of the cleanup candidate rooted exactly at this folder, if there is one.
    func safety(of id: Int32) -> Safety?
}
```

- No default implementation for `totalCloneAware`/`ownCloneAware` (no protocol extension falling back to
  `totalAlloc`): a conformer that forgets them must fail to compile instead of silently drawing inflated sizes.
- The numbers map one to one onto `DirNode.totalCloneAware` / `DirNode.ownCloneAware`
  (`Sources/ScanCore/DiskTree.swift:20,26`). The layout assumes only that every value is `>= 0`. It must not
  assume `totalCloneAware <= totalAlloc`: that holds for a normal scan, but after a `--private` scan the allocated
  numbers are private bytes (`ATTR_CMNEXT_PRIVATESIZE`) while clone-aware numbers are always from
  `ATTR_FILE_ALLOCSIZE`, so either can be larger.

### 8.2 Size mode **[Change]** (#19)

```swift
/// Which size the layout ranks and draws.
public enum MapSizeMode: Sendable, Equatable {
    /// Each APFS full-clone family counted once (default; "on disk").
    case cloneAware
    /// Allocated bytes as `du` counts them (every clone in full; private bytes for a `--private` scan).
    case allocated
}

public static func build<S: MapSource>(_ source: S, node: Int32, size: CGSize,
                                       mode: MapSizeMode = .cloneAware) -> MapLayout
```

Behaviour:

- `items(_:of:mode:)` reads `total(c)` = `mode == .cloneAware ? totalCloneAware(of: c) : totalAlloc(of: c)` and
  `own(node)` = `ownCloneAware` or `ownAlloc` likewise. Everything else in section 6 is unchanged, with
  "`totalAlloc`" replaced by `total` and "`ownAlloc`" by `own`. `total(c)` is read once per child (store it in the
  `Item`), removing the double call.
- The empty-input guard uses `total(node) > 0`.
- In `.cloneAware` mode a folder whose clone-aware total is 0 (all its blocks belong to clone families owned
  elsewhere, e.g. a clone cache inside a scan of `/`) gets no tile. This is intended: it frees nothing on its own.
- `MapTile.bytes` and `sizeText` are in the selected mode. No field records the mode; the caller knows it.
- The default is `.cloneAware`, so existing callers get the corrected sizes without a source change.

### 8.3 `seconds` **[Change]** (#19)

Decision: remove `MapLayout.seconds`. `MapLayout` becomes:

```swift
public struct MapLayout {
    public var tiles: [MapTile] = []
    public init(tiles: [MapTile] = []) { self.tiles = tiles }
}
```

Reason: the layout is a pure function of its input; a timing field makes two equal layouts unequal and was never
filled. A caller that wants to time `build` wraps the call in `ContinuousClock().measure { ... }`. This is a
source-breaking change of a public API; acceptable before 1.0 and noted in `CHANGELOG.md` (chapter 07, #28).

### 8.4 Tests to add **[New]** (#19)

In `Tests/MapCoreTests/LayoutTests.swift`:

- `FakeTree.Node` gets `var cloneAware: Int64? = nil` (own clone-aware bytes; `nil` means equal to `own`).
  `ownCloneAware(of:)` returns `cloneAware ?? own`; `totalCloneAware(of:)` sums recursively like `totalAlloc`.
  All existing tests keep passing unchanged, because without clones both modes give the same numbers.
- `cloneAwareRanking`: root with `clones` (own 9,000,000, cloneAware 3,000,000) and `plain` (own 5,000,000).
  Default mode: depth-0 order `plain` then `clones`; `clones` tile bytes 3,000,000; depth-0 bytes sum to
  `totalCloneAware(of: 0)` (8,000,000). `mode: .allocated`: order `clones` then `plain`, bytes 9,000,000 and 5,000,000.
- `cloneAwareZeroFolderHidden`: a folder with own 4,000,000 and cloneAware 0 has no tile in `.cloneAware` mode
  and a tile in `.allocated` mode.
- `cloneAwareFilesTile`: root own 2,000,000 with cloneAware 500,000: the `.files` tile has 500,000 bytes by default.
- `cloneAwareEmptyRoot`: a tree whose root total clone-aware size is 0 gives no tiles by default.
- Not tested: `seconds` (removed; the compiler checks callers).

Also add, closing gaps from section 7 **[New]**: `expandThreshold` (a depth-0 folder of 59 points width gets
`expanded == false`, one of 60 x 40 gets children) and `smallLabels` (every depth-1 tile with width < 40 or
height < 14 has an empty `sizeText`). These need the 60/40/40/14 literals exposed:

- **[Change]** (#19, same PR) Promote them to `public static let expandMinWidth: CGFloat = 60`,
  `expandMinHeight: CGFloat = 40`, `labelMinWidth: CGFloat = 40`, `labelMinHeight: CGFloat = 14`,
  `innerInset: CGFloat = 1` on `MapLayouter`, and use them in `build`. Values unchanged.

Check: `swift test --filter MapCoreTests` passes; `swift build -c release` has no warnings in `Sources/MapCore`.

## As built

- **#19.** Built as in section 8. `MapSource` gained `totalCloneAware(of:)` and `ownCloneAware(of:)` with no
  default implementation (section 8.1), so the change is source-breaking for every external conformer: it must
  add both methods (a tree without clones can return `totalAlloc`/`ownAlloc`). `MapLayouter.build` gained
  `mode: MapSizeMode = .cloneAware`, which is source-compatible for callers but changes the sizes they get.
  `MapLayout.seconds` and the `seconds:` initializer parameter are removed (source-breaking). The five literals
  became `expandMinWidth`, `expandMinHeight`, `labelMinWidth`, `labelMinHeight` and `innerInset`. The `MapSource`
  and `owner` doc comments were reworded.

## Glossary additions

- **Squarified treemap**: a treemap whose rectangles are laid out row by row along the shorter side of the free
  space, adding items to a row only while the worst aspect ratio does not get worse (Bruls, Huizing, van Wijk).
- **Tile**: one rectangle of a layout (`MapTile`): a folder, the files directly inside a folder, or a merged rest.
- **Level / depth**: depth 0 = the children of the folder being shown; depth 1 = their children, drawn inside an
  expanded depth-0 folder. MapCore never lays out deeper.
- **Expanded tile**: a depth-0 folder tile large enough (60 x 40 points) to have its children drawn inside it,
  below a 16-point header strip.
- **Rest tile**: one tile (`.rest(count:)`) that stands for the smallest items of a folder beyond the first 299.
- **Files tile**: one tile (`.files`) for all files directly inside a folder.
- **Inherited safety**: the safety level of the nearest cleanup candidate at or above the shown folder, applied to
  every tile that has no candidate of its own.
- **Size mode**: whether a layout ranks and draws clone-aware bytes (default) or allocated bytes (`MapSizeMode`).
- **MapSource**: the protocol a scanned tree implements so MapCore can lay it out.
