import CleanCore
import CoreGraphics
import Foundation

/// What the Disk Map needs to know about a scanned tree. The app's `DiskSnapshot` conforms; tests use a fake.
public protocol MapSource {
    /// Children of a folder, largest first.
    func children(of id: Int32) -> ArraySlice<Int32>
    /// Size on disk of a folder including everything below it.
    func totalAlloc(of id: Int32) -> Int64
    /// Size on disk of the files directly inside a folder.
    func ownAlloc(of id: Int32) -> Int64
    func name(of id: Int32) -> String
    func parent(of id: Int32) -> Int32?
    /// Safety of the cleanup candidate rooted exactly at this folder, if there is one.
    func safety(of id: Int32) -> Safety?
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
    /// The folder whose content this tile belongs to (the tile's own folder for `.folder`).
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
    public var seconds: Double = 0

    public init(tiles: [MapTile] = [], seconds: Double = 0) {
        self.tiles = tiles
        self.seconds = seconds
    }
}

/// Lays out one folder plus the level below it as squarified treemaps.
public enum MapLayouter {
    /// Rectangles smaller than this on either side are skipped.
    public static let minSide: CGFloat = 3
    /// Items laid out one by one per level; the tail is merged into one `.rest` tile.
    public static let maxItems = 300
    /// Room for a folder's name above its children.
    public static let headerHeight: CGFloat = 16

    private struct Item {
        var kind: MapTile.Kind
        var bytes: Int64
        var name: String
    }

    /// Children of a folder plus its own files, largest first; the tail beyond `maxItems` is merged.
    private static func items<S: MapSource>(_ source: S, of node: Int32) -> [Item] {
        var out: [Item] = []
        for c in source.children(of: node) where source.totalAlloc(of: c) > 0 {
            out.append(Item(kind: .folder(c), bytes: source.totalAlloc(of: c), name: source.name(of: c)))
        }
        let own = source.ownAlloc(of: node)
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

    public static func build<S: MapSource>(_ source: S, node: Int32, size: CGSize) -> MapLayout {
        var tiles: [MapTile] = []
        guard size.width > 0, size.height > 0, source.totalAlloc(of: node) > 0 else { return MapLayout() }
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

        let top = items(source, of: node)
        let topRects = squarify(values: top.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
        for (i, item) in top.enumerated() {
            let r = topRects[i]
            guard r.width >= minSide, r.height >= minSide else { continue }
            var safety = inherited
            var inner: [Item] = []
            if case .folder(let f) = item.kind {
                safety = source.safety(of: f) ?? inherited
                if r.width >= 60, r.height >= 40 { inner = items(source, of: f) }
            }
            let expanded = !inner.isEmpty
            tiles.append(MapTile(id: tiles.count, kind: item.kind, owner: node, rect: r, depth: 0, bytes: item.bytes,
                                 name: item.name, safety: safety, expanded: expanded, sizeText: sizeText(item.bytes)))
            guard expanded, case .folder(let f) = item.kind else { continue }
            let area = CGRect(x: r.minX + 1, y: r.minY + headerHeight, width: r.width - 2, height: r.height - headerHeight - 1)
            guard area.width > minSide, area.height > minSide else { continue }
            let rects = squarify(values: inner.map { Double($0.bytes) }, in: area)
            for (j, child) in inner.enumerated() {
                let cr = rects[j]
                guard cr.width >= minSide, cr.height >= minSide else { continue }
                var cs = safety
                if case .folder(let c) = child.kind { cs = source.safety(of: c) ?? safety }
                let labelled = cr.width >= 40 && cr.height >= 14
                tiles.append(MapTile(id: tiles.count, kind: child.kind, owner: f, rect: cr, depth: 1, bytes: child.bytes,
                                     name: child.name, safety: cs, expanded: false,
                                     sizeText: labelled ? sizeText(child.bytes) : ""))
            }
        }
        return MapLayout(tiles: tiles)
    }
}
