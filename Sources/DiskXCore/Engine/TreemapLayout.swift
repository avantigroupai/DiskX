import Foundation
import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000).
/// Pure geometry: maps weighted items into sub-rects of a container, keeping
/// aspect ratios close to 1 so tiles stay readable and clickable.
public enum TreemapLayout {
    public struct Item {
        public let id: UInt64
        public let weight: Double
        public init(id: UInt64, weight: Double) {
            self.id = id
            self.weight = weight
        }
    }

    public struct Placement {
        public let id: UInt64
        public let rect: CGRect
    }

    /// Items must be sorted by weight descending for good squarification.
    /// Zero/negative weights are skipped. Rects tile `rect` exactly.
    public static func layout(items: [Item], in rect: CGRect) -> [Placement] {
        let positive = items.filter { $0.weight > 0 }
        let total = positive.reduce(0.0) { $0 + $1.weight }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }

        // Normalize weights to the rect's area.
        let area = Double(rect.width * rect.height)
        let scaled = positive.map { Item(id: $0.id, weight: $0.weight / total * area) }

        var placements: [Placement] = []
        placements.reserveCapacity(scaled.count)
        var remaining = rect
        var row: [Item] = []
        var index = 0

        func shortestSide() -> Double { Double(min(remaining.width, remaining.height)) }

        func worstAspect(_ row: [Item], side: Double) -> Double {
            guard !row.isEmpty, side > 0 else { return .infinity }
            let sum = row.reduce(0.0) { $0 + $1.weight }
            guard sum > 0 else { return .infinity }
            let maxW = row.map(\.weight).max()!
            let minW = row.map(\.weight).min()!
            let s2 = side * side
            return max(s2 * maxW / (sum * sum), sum * sum / (s2 * minW))
        }

        func layoutRow(_ row: [Item]) {
            let sum = row.reduce(0.0) { $0 + $1.weight }
            guard sum > 0 else { return }
            let horizontal = remaining.width >= remaining.height
            if horizontal {
                // Row is a vertical strip on the left.
                let stripWidth = CGFloat(sum / Double(remaining.height))
                var y = remaining.minY
                for item in row {
                    let h = CGFloat(item.weight / sum) * remaining.height
                    placements.append(Placement(id: item.id,
                                                rect: CGRect(x: remaining.minX, y: y, width: stripWidth, height: h)))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + stripWidth, y: remaining.minY,
                                   width: remaining.width - stripWidth, height: remaining.height)
            } else {
                // Row is a horizontal strip on the top.
                let stripHeight = CGFloat(sum / Double(remaining.width))
                var x = remaining.minX
                for item in row {
                    let w = CGFloat(item.weight / sum) * remaining.width
                    placements.append(Placement(id: item.id,
                                                rect: CGRect(x: x, y: remaining.minY, width: w, height: stripHeight)))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + stripHeight,
                                   width: remaining.width, height: remaining.height - stripHeight)
            }
        }

        while index < scaled.count {
            let item = scaled[index]
            let side = shortestSide()
            if row.isEmpty || worstAspect(row + [item], side: side) <= worstAspect(row, side: side) {
                row.append(item)
                index += 1
            } else {
                layoutRow(row)
                row = []
            }
        }
        if !row.isEmpty { layoutRow(row) }
        return placements
    }
}
