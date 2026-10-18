import CoreGraphics
import MapCore
import Testing

/// Deterministic generator, so a failing case can be reproduced.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomValues(seed: UInt64, count: Int) -> [Double] {
    var g = SplitMix(state: seed)
    return (0..<count).map { _ in Double.random(in: 1...1_000_000, using: &g) }.sorted(by: >)
}

private func area(_ r: CGRect) -> Double { Double(r.width) * Double(r.height) }

@Suite("squarify")
struct SquarifyTests {
    static let frames: [CGRect] = [
        CGRect(x: 0, y: 0, width: 800, height: 600),
        CGRect(x: 10, y: 20, width: 300, height: 900),
        CGRect(x: 0, y: 0, width: 1000, height: 40),
        CGRect(x: 5, y: 5, width: 77, height: 77),
    ]

    @Test("areas are proportional to the values", arguments: frames, [1, 2, 7, 60, 300])
    func proportional(frame: CGRect, count: Int) {
        let values = randomValues(seed: UInt64(count) &* 7919, count: count)
        let rects = squarify(values: values, in: frame)
        #expect(rects.count == count)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            let expected = v / total * area(frame)
            #expect(abs(area(r) - expected) <= max(1e-6 * area(frame), expected * 1e-6), "value \(v)")
        }
    }

    @Test("the rectangles tile the frame exactly", arguments: frames, [1, 3, 25, 200])
    func tilesExactly(frame: CGRect, count: Int) {
        let rects = squarify(values: randomValues(seed: UInt64(count) &* 31, count: count), in: frame)
        let sum = rects.reduce(0) { $0 + area($1) }
        #expect(abs(sum - area(frame)) <= 1e-6 * area(frame))
        let eps: CGFloat = 1e-6
        for r in rects {
            #expect(r.minX >= frame.minX - eps && r.minY >= frame.minY - eps)
            #expect(r.maxX <= frame.maxX + eps && r.maxY <= frame.maxY + eps)
        }
    }

    @Test("rectangles do not overlap", arguments: frames, [2, 12, 80])
    func noOverlap(frame: CGRect, count: Int) {
        let rects = squarify(values: randomValues(seed: UInt64(count) &* 101, count: count), in: frame)
        var worst = 0.0
        for i in rects.indices {
            for j in rects.indices where j > i {
                let inter = rects[i].intersection(rects[j])
                if !inter.isNull { worst = max(worst, area(inter)) }
            }
        }
        // Edges touch (zero area); allow only floating-point dust.
        #expect(worst <= 1e-6 * area(frame), "largest overlap \(worst)")
    }

    @Test("edge cases: empty input, zero weights, degenerate frame")
    func edgeCases() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(squarify(values: [], in: frame).isEmpty)
        #expect(squarify(values: [0, 0], in: frame) == [.zero, .zero])
        #expect(squarify(values: [5], in: frame) == [frame])
        #expect(squarify(values: [3, 2], in: CGRect(x: 0, y: 0, width: 0, height: 50)) == [.zero, .zero])
        let withZero = squarify(values: [4, 4, 0], in: frame)
        #expect(withZero[2] == .zero)
        #expect(abs(area(withZero[0]) - 5000) < 1e-6)
    }

    @Test("a typical set stays reasonably square")
    func aspectRatios() {
        let rects = squarify(values: [600, 600, 400, 400, 200, 200], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        for r in rects {
            let ratio = max(r.width / r.height, r.height / r.width)
            #expect(ratio < 4)
        }
    }
}
