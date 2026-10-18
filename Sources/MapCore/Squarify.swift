import CoreGraphics

/// Squarified treemap (Bruls, Huizing, van Wijk). Pure function: no UI, no tree.
///
/// - Parameters:
///   - values: non-negative weights, sorted largest first (the algorithm assumes this order).
///   - rect: the frame to tile.
/// - Returns: one rectangle per value, same order. Rectangle areas are proportional to the values and
///   together tile `rect` exactly. Zero values (and an all-zero input) get empty rectangles.
public func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
    let n = values.count
    var out = [CGRect](repeating: .zero, count: n)
    let sum = values.reduce(0, +)
    guard n > 0, sum > 0, rect.width > 0, rect.height > 0 else { return out }
    let scale = Double(rect.width * rect.height) / sum
    var free = rect
    var i = 0
    while i < n, values[i] > 0 {
        let short = Double(min(free.width, free.height))
        // Grow the row while the worst aspect ratio does not get worse.
        var j = i
        var rowSum = 0.0
        var worst = Double.infinity
        while j < n, values[j] > 0 {
            let s = rowSum + values[j] * scale
            let hi = values[i] * scale, lo = values[j] * scale
            let w = max(short * short * hi / (s * s), s * s / (short * short * lo))
            if w > worst { break }
            worst = w
            rowSum = s
            j += 1
        }
        let last = j >= n || values[j] <= 0
        if free.width >= free.height {
            // Column on the left, items stacked top to bottom.
            let w = last ? free.width : CGFloat(rowSum / Double(free.height))
            var y = free.minY
            for k in i..<j {
                let h = k == j - 1 ? free.maxY - y : CGFloat(values[k] * scale / Double(w))
                out[k] = CGRect(x: free.minX, y: y, width: w, height: h)
                y += h
            }
            free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
        } else {
            // Row on top, items laid left to right.
            let h = last ? free.height : CGFloat(rowSum / Double(free.width))
            var x = free.minX
            for k in i..<j {
                let w = k == j - 1 ? free.maxX - x : CGFloat(values[k] * scale / Double(h))
                out[k] = CGRect(x: x, y: free.minY, width: w, height: h)
                x += w
            }
            free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
        }
        i = j
    }
    return out
}
