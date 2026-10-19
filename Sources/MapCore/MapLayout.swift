import CleanCore
import CoreGraphics
import Foundation

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

/// Which size the layout ranks and draws.
public enum MapSizeMode: Sendable, Equatable {
    /// Each APFS full-clone family counted once (default; "on disk").
    case cloneAware
    /// Allocated bytes as `du` counts them (every clone in full; private bytes for a `--private` scan).
    case allocated
}

/// One drawn rectangle of the Disk Map.
public struct MapTile: Identifiable {
    public enum Kind: Equatable {
        case folder(Int32)
        /// The files directly inside `owner`, as one rectangle.
        case files
        /// The small items of `owner` that were not laid out one by one.
        case rest(count: Int)
    }

    public let id: Int
    public let kind: Kind
    /// The folder whose content this tile belongs to (for a `.folder` tile, its parent).
    public let owner: Int32
    public let rect: CGRect
    /// 0 = current level, 1 = one level below.
    public let depth: Int
    public let bytes: Int64
    /// The folder's name; empty for `.files` and `.rest`, whose text the UI localizes.
    public let name: String
    public let safety: Safety?
    /// Level-0 folder tile that has its children drawn inside it.
    public let expanded: Bool
    public let sizeText: String

    public var folder: Int32? { if case .folder(let n) = kind { n } else { nil } }
}

public struct MapLayout {
    public var tiles: [MapTile] = []

    public init(tiles: [MapTile] = []) { self.tiles = tiles }
}

/// Lays out one folder plus the level below it as squarified treemaps.
public enum MapLayouter {
    /// Rectangles smaller than this on either side are skipped.
    public static let minSide: CGFloat = 3
    /// Items laid out one by one per level; the tail is merged into one `.rest` tile.
    public static let maxItems = 300
    /// Room for a folder's name above its children.
    public static let headerHeight: CGFloat = 16
    /// A depth-0 folder expands only if its rectangle is at least this wide ...
    public static let expandMinWidth: CGFloat = 60
    /// ... and this high.
    public static let expandMinHeight: CGFloat = 40
    /// A depth-1 tile gets `sizeText` only if it is at least this wide ...
    public static let labelMinWidth: CGFloat = 40
    /// ... and this high.
    public static let labelMinHeight: CGFloat = 14
    /// Children area = rectangle inset by this on left, right and bottom (and by `headerHeight` on top).
    public static let innerInset: CGFloat = 1

    private struct Item {
        var kind: MapTile.Kind
        var bytes: Int64
        var name: String
    }

    /// Children of a folder plus its own files, largest first; the tail beyond `maxItems` is merged.
    private static func total<S: MapSource>(_ source: S, _ id: Int32, _ mode: MapSizeMode) -> Int64 {
        mode == .cloneAware ? source.totalCloneAware(of: id) : source.totalAlloc(of: id)
    }

    private static func items<S: MapSource>(_ source: S, of node: Int32, mode: MapSizeMode) -> [Item] {
        var out: [Item] = []
        for c in source.children(of: node) {
            let bytes = total(source, c, mode)
            if bytes > 0 { out.append(Item(kind: .folder(c), bytes: bytes, name: source.name(of: c))) }
        }
        let own = mode == .cloneAware ? source.ownCloneAware(of: node) : source.ownAlloc(of: node)
        if own > 0 { out.append(Item(kind: .files, bytes: own, name: "")) }
        out.sort { $0.bytes > $1.bytes }
        if out.count > maxItems {
            let tail = out[(maxItems - 1)...]
            let rest = Item(kind: .rest(count: tail.count), bytes: tail.reduce(0) { $0 + $1.bytes }, name: "")
            out.removeSubrange((maxItems - 1)...)
            out.append(rest)
            out.sort { $0.bytes > $1.bytes }
        }
        return out
    }

    public static func build<S: MapSource>(
        _ source: S, node: Int32, size: CGSize, mode: MapSizeMode = .cloneAware
    ) -> MapLayout {
        var tiles: [MapTile] = []
        guard size.width > 0, size.height > 0, total(source, node, mode) > 0 else { return MapLayout() }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        func sizeText(_ b: Int64) -> String { formatter.string(fromByteCount: b) }

        // A candidate above the current folder colours everything inside it.
        var inherited: Safety?
        var p: Int32? = node
        while let n = p, inherited == nil {
            inherited = source.safety(of: n)
            p = source.parent(of: n)
        }

        let top = items(source, of: node, mode: mode)
        let topRects = squarify(values: top.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
        for (i, item) in top.enumerated() {
            let r = topRects[i]
            guard r.width >= minSide, r.height >= minSide else { continue }
            var safety = inherited
            var inner: [Item] = []
            if case .folder(let f) = item.kind {
                safety = source.safety(of: f) ?? inherited
                if r.width >= expandMinWidth, r.height >= expandMinHeight {
                    inner = items(source, of: f, mode: mode)
                }
            }
            let expanded = !inner.isEmpty
            tiles.append(
                MapTile(
                    id: tiles.count, kind: item.kind, owner: node, rect: r, depth: 0, bytes: item.bytes,
                    name: item.name, safety: safety, expanded: expanded, sizeText: sizeText(item.bytes)))
            guard expanded, case .folder(let f) = item.kind else { continue }
            let area = CGRect(
                x: r.minX + innerInset, y: r.minY + headerHeight, width: r.width - 2 * innerInset,
                height: r.height - headerHeight - innerInset)
            guard area.width > minSide, area.height > minSide else { continue }
            let rects = squarify(values: inner.map { Double($0.bytes) }, in: area)
            for (j, child) in inner.enumerated() {
                let cr = rects[j]
                guard cr.width >= minSide, cr.height >= minSide else { continue }
                var cs = safety
                if case .folder(let c) = child.kind { cs = source.safety(of: c) ?? safety }
                let labelled = cr.width >= labelMinWidth && cr.height >= labelMinHeight
                tiles.append(
                    MapTile(
                        id: tiles.count, kind: child.kind, owner: f, rect: cr, depth: 1, bytes: child.bytes,
                        name: child.name, safety: cs, expanded: false,
                        sizeText: labelled ? sizeText(child.bytes) : ""))
            }
        }
        return MapLayout(tiles: tiles)
    }
}
