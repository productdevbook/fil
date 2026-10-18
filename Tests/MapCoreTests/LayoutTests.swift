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

    @Test("tile ids are their positions")
    func idsAreSequential() {
        let layout = MapLayouter.build(sample(), node: 0, size: size)
        #expect(layout.tiles.map(\.id) == Array(layout.tiles.indices))
    }
}
