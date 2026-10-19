import CleanCore
import CoreGraphics
import MapCore
import Testing

/// A small in-memory tree. Node 0 is the root; children are listed largest first.
private struct FakeTree: MapSource {
    struct Node {
        var name: String
        var parent: Int32
        var own: Int64 = 0
        var safety: Safety?
        /// Own clone-aware bytes; nil means equal to `own`.
        var cloneAware: Int64?
    }
    var nodes: [Node]

    func children(of id: Int32) -> ArraySlice<Int32> {
        let kids = nodes.indices.filter { nodes[$0].parent == id && $0 != 0 }.map(Int32.init)
        return kids.sorted { totalAlloc(of: $0) > totalAlloc(of: $1) }[...]
    }
    func totalAlloc(of id: Int32) -> Int64 {
        nodes[Int(id)].own + children(of: id).reduce(0) { $0 + totalAlloc(of: $1) }
    }
    func ownAlloc(of id: Int32) -> Int64 { nodes[Int(id)].own }
    func ownCloneAware(of id: Int32) -> Int64 { nodes[Int(id)].cloneAware ?? nodes[Int(id)].own }
    func totalCloneAware(of id: Int32) -> Int64 {
        ownCloneAware(of: id) + children(of: id).reduce(0) { $0 + totalCloneAware(of: $1) }
    }
    func name(of id: Int32) -> String { nodes[Int(id)].name }
    func parent(of id: Int32) -> Int32? { id == 0 ? nil : nodes[Int(id)].parent }
    func safety(of id: Int32) -> Safety? { nodes[Int(id)].safety }
}

private let size = CGSize(width: 800, height: 600)

private func sample() -> FakeTree {
    FakeTree(nodes: [
        .init(name: "~", parent: -1, own: 1_000_000),  // 0
        .init(name: "Library", parent: 0, own: 100),  // 1
        .init(name: "Caches", parent: 1, own: 6_000_000, safety: .safe),  // 2
        .init(name: "Logs", parent: 1, own: 2_000_000),  // 3
        .init(name: "proj", parent: 0, own: 4_000_000),  // 4
        .init(name: "node_modules", parent: 4, own: 3_000_000, safety: .review),  // 5
    ])
}

@Suite("Disk Map level layout")
struct LayoutTests {
    @Test("tiles of the current level tile the frame")
    func topLevelFillsFrame() {
        let layout = MapLayouter.build(sample(), node: 0, size: size)
        let top = layout.tiles.filter { $0.depth == 0 }
        #expect(top.count == 3)  // Library, proj, files of ~
        let sum = top.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(sum - Double(size.width * size.height)) < 1)
        #expect(top.map(\.bytes) == top.map(\.bytes).sorted(by: >))
    }

    @Test("sizes and kinds")
    func kinds() {
        let layout = MapLayouter.build(sample(), node: 0, size: size)
        let top = layout.tiles.filter { $0.depth == 0 }
        #expect(top[0].kind == .folder(1) && top[0].bytes == 8_000_100)
        #expect(top[1].kind == .folder(4) && top[1].bytes == 7_000_000)
        #expect(top[2].kind == .files && top[2].bytes == 1_000_000)
        #expect(top[2].name.isEmpty)  // the UI localizes the text
        #expect(top[0].name == "Library")
    }

    @Test("children are drawn inside their expanded parent, below its header")
    func childrenInsideParent() {
        let layout = MapLayouter.build(sample(), node: 0, size: size)
        for child in layout.tiles where child.depth == 1 {
            let parent = layout.tiles.first { $0.kind == .folder(child.owner) && $0.depth == 0 }
            #expect(parent != nil)
            if let p = parent {
                #expect(p.expanded)
                #expect(p.rect.insetBy(dx: -0.001, dy: -0.001).contains(child.rect))
                #expect(child.rect.minY >= p.rect.minY + MapLayouter.headerHeight - 0.001)
            }
        }
        #expect(layout.tiles.contains { $0.depth == 1 })
    }

    @Test("a candidate colours its tile and everything inside; an ancestor candidate colours the whole view")
    func safetyColours() {
        let layout = MapLayouter.build(sample(), node: 0, size: size)
        let nm = layout.tiles.first { $0.kind == .folder(5) }
        #expect(nm?.safety == .review)
        let caches = layout.tiles.first { $0.kind == .folder(2) }
        #expect(caches?.safety == .safe)
        #expect(layout.tiles.first { $0.kind == .folder(3) }?.safety == nil)

        // Zoomed into a candidate: its children inherit the candidate's safety.
        let inside = MapLayouter.build(sample(), node: 5, size: size)
        #expect(inside.tiles.allSatisfy { $0.safety == .review })
    }

    @Test("tiny rectangles are skipped")
    func skipsTinyTiles() {
        var nodes: [FakeTree.Node] = [.init(name: "~", parent: -1)]
        nodes.append(.init(name: "big", parent: 0, own: 1_000_000_000))
        nodes.append(.init(name: "speck", parent: 0, own: 10))
        let layout = MapLayouter.build(FakeTree(nodes: nodes), node: 0, size: CGSize(width: 300, height: 200))
        #expect(layout.tiles.filter { $0.depth == 0 }.count == 1)
        #expect(
            layout.tiles.allSatisfy { $0.rect.width >= MapLayouter.minSide && $0.rect.height >= MapLayouter.minSide })
    }

    @Test("more than maxItems folders: the tail becomes one 'rest' tile that carries its bytes")
    func mergesTail() {
        var nodes: [FakeTree.Node] = [.init(name: "~", parent: -1)]
        let count = MapLayouter.maxItems + 50
        for i in 0..<count { nodes.append(.init(name: "d\(i)", parent: 0, own: Int64(1_000_000 + i))) }
        let tree = FakeTree(nodes: nodes)
        let layout = MapLayouter.build(tree, node: 0, size: CGSize(width: 4000, height: 3000))
        let rest = layout.tiles.filter { if case .rest = $0.kind { true } else { false } }
        #expect(rest.count == 1)
        guard case .rest(let n) = rest[0].kind else { return }
        #expect(n == count - (MapLayouter.maxItems - 1))
        let top = layout.tiles.filter { $0.depth == 0 }
        #expect(top.count == MapLayouter.maxItems)
        #expect(top.reduce(0) { $0 + $1.bytes } == tree.totalAlloc(of: 0))
    }

    @Test("empty or zero-sized input gives no tiles")
    func emptyInputs() {
        #expect(MapLayouter.build(sample(), node: 0, size: .zero).tiles.isEmpty)
        let empty = FakeTree(nodes: [.init(name: "~", parent: -1)])
        #expect(MapLayouter.build(empty, node: 0, size: size).tiles.isEmpty)
    }

    private func clones() -> FakeTree {
        FakeTree(nodes: [
            .init(name: "~", parent: -1),
            .init(name: "clones", parent: 0, own: 9_000_000, cloneAware: 3_000_000),
            .init(name: "plain", parent: 0, own: 5_000_000),
        ])
    }

    @Test("clone-aware sizes rank the tree; allocated mode ranks by du")
    func cloneAwareRanking() {
        let tree = clones()
        let top = MapLayouter.build(tree, node: 0, size: size).tiles.filter { $0.depth == 0 }
        #expect(top.map(\.kind) == [.folder(2), .folder(1)])
        #expect(top[1].bytes == 3_000_000)
        #expect(top.reduce(0) { $0 + $1.bytes } == tree.totalCloneAware(of: 0))
        #expect(tree.totalCloneAware(of: 0) == 8_000_000)
        let alloc = MapLayouter.build(tree, node: 0, size: size, mode: .allocated).tiles.filter { $0.depth == 0 }
        #expect(alloc.map(\.kind) == [.folder(1), .folder(2)])
        #expect(alloc.map(\.bytes) == [9_000_000, 5_000_000])
    }

    @Test("a clone family is counted once")
    func cloneFamilyOnce() {
        // The family's 6 MB is owned by `a`; `b` holds a clone of it and owns nothing.
        let tree = FakeTree(nodes: [
            .init(name: "~", parent: -1),
            .init(name: "a", parent: 0, own: 6_000_000),
            .init(name: "b", parent: 0, own: 6_000_000, cloneAware: 0),
        ])
        let layout = MapLayouter.build(tree, node: 0, size: size)
        let top = layout.tiles.filter { $0.depth == 0 }
        #expect(top.map(\.kind) == [.folder(1)])
        #expect(top.reduce(0) { $0 + $1.bytes } == 6_000_000)
        #expect(
            MapLayouter.build(tree, node: 0, size: size, mode: .allocated).tiles.filter { $0.depth == 0 }.count == 2)
    }

    @Test("a folder with clone-aware size 0 has no tile, except in allocated mode")
    func cloneAwareZeroFolderHidden() {
        let tree = FakeTree(nodes: [
            .init(name: "~", parent: -1),
            .init(name: "big", parent: 0, own: 5_000_000),
            .init(name: "cache", parent: 0, own: 4_000_000, cloneAware: 0),
        ])
        #expect(MapLayouter.build(tree, node: 0, size: size).tiles.allSatisfy { $0.kind != .folder(2) })
        #expect(MapLayouter.build(tree, node: 0, size: size, mode: .allocated).tiles.contains { $0.kind == .folder(2) })
    }

    @Test("the files tile uses clone-aware bytes by default")
    func cloneAwareFilesTile() {
        let tree = FakeTree(nodes: [
            .init(name: "~", parent: -1, own: 2_000_000, cloneAware: 500_000),
            .init(name: "d", parent: 0, own: 1_000_000),
        ])
        let files = MapLayouter.build(tree, node: 0, size: size).tiles.first { $0.kind == .files && $0.depth == 0 }
        #expect(files?.bytes == 500_000)
    }

    @Test("a root with clone-aware size 0 gives no tiles by default")
    func cloneAwareEmptyRoot() {
        let tree = FakeTree(nodes: [.init(name: "~", parent: -1, own: 1_000_000, cloneAware: 0)])
        #expect(MapLayouter.build(tree, node: 0, size: size).tiles.isEmpty)
        #expect(!MapLayouter.build(tree, node: 0, size: size, mode: .allocated).tiles.isEmpty)
    }

    private func folderTiles(width: CGFloat, height: CGFloat) -> [MapTile] {
        let tree = FakeTree(nodes: [
            .init(name: "~", parent: -1),
            .init(name: "f", parent: 0),
            .init(name: "g", parent: 1, own: 1_000_000),
            .init(name: "h", parent: 1, own: 1_000_000),
        ])
        return MapLayouter.build(tree, node: 0, size: CGSize(width: width, height: height)).tiles
    }

    @Test("a folder expands only from 60 x 40 points")
    func expandThreshold() {
        #expect(folderTiles(width: 59, height: 100).first?.expanded == false)
        #expect(folderTiles(width: 100, height: 39).first?.expanded == false)
        let ok = folderTiles(width: 60, height: 40)
        #expect(ok.first?.expanded == true)
        #expect(ok.contains { $0.depth == 1 })
    }

    @Test("small depth-1 tiles carry no size text")
    func smallLabels() {
        var nodes: [FakeTree.Node] = [.init(name: "~", parent: -1), .init(name: "f", parent: 0)]
        for i in 0..<30 { nodes.append(.init(name: "c\(i)", parent: 1, own: Int64(1_000_000 * (i + 1)))) }
        let tiles = MapLayouter.build(FakeTree(nodes: nodes), node: 0, size: CGSize(width: 200, height: 150)).tiles
        let inner = tiles.filter { $0.depth == 1 }
        #expect(!inner.isEmpty)
        for t in inner {
            let small = t.rect.width < MapLayouter.labelMinWidth || t.rect.height < MapLayouter.labelMinHeight
            #expect(t.sizeText.isEmpty == small)
        }
    }

    @Test("tile ids are their positions")
    func idsAreSequential() {
        let layout = MapLayouter.build(sample(), node: 0, size: size)
        #expect(layout.tiles.map(\.id) == Array(layout.tiles.indices))
    }
}
