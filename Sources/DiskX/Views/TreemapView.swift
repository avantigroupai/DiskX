import SwiftUI
import DiskXCore

// MARK: - Tile geometry

/// One rectangle in the treemap: a direct child of the current node, or —
/// inside large directory tiles — one of that directory's children (a sub-tile).
private struct TreemapTile: Identifiable {
    let node: FileNode
    let rect: CGRect
    let tier: SafetyTier
    let topLevelID: UInt64
    let isSubTile: Bool
    /// Top-level directory tile that reserved a label band and shows sub-tiles.
    let hasLabelBand: Bool
    var id: UInt64 { node.id }
}

private struct TileCacheKey: Equatable {
    let nodeID: UInt64
    let width: CGFloat
    let height: CGFloat
    let rowsCount: Int
    let allocated: Int64
    let hasAnalyzer: Bool
}

/// Reference box: memoized geometry refreshed during body evaluation without
/// dirtying SwiftUI-observed state. Also serves gesture/hover hit-testing.
private final class TileCache {
    var key: TileCacheKey?
    var tiles: [TreemapTile] = []
    var topLevelByID: [UInt64: FileNode] = [:]
}

private struct HoverReadout: Equatable {
    let id: UInt64
    let name: String
    let bytes: Int64
    let tierLabel: String
    let location: CGPoint
}

// MARK: - TreemapView

/// The Map pane: a squarified treemap of the current directory's children,
/// drawn in a single Canvas. Brightness encodes safety tier (monochrome);
/// the accent color is reserved for selection and cursor.
/// Keyboard is handled globally (KeyboardDispatch) — this view is mouse-only.
struct TreemapView: View {
    let model: AppModel

    @State private var cache = TileCache()
    @State private var hover: HoverReadout?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read observable state in body so @Observable dependency tracking
        // registers here (not inside the escaping Canvas renderer).
        let current = model.currentNode
        let analyzer = model.analyzer
        let phase = model.phase
        let selected = model.selectedIDs
        let cursorID = model.cursorRow?.id
        let markedIDs = Set(model.marks.keys)
        let rowsCount = model.rows.count

        GeometryReader { geo in
            let tiles = cachedTiles(for: current, size: geo.size, analyzer: analyzer, rowsCount: rowsCount)
            ZStack(alignment: .topLeading) {
                if tiles.isEmpty {
                    emptyState(phase: phase)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    tileCanvas(tiles: tiles,
                               selected: selected,
                               cursorID: cursorID,
                               markedIDs: markedIDs,
                               hoveredID: hover?.id)
                    if let hover {
                        readout(hover)
                            .offset(readoutOffset(hover, in: geo.size))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover == nil)
        }
        .clipped()
        .onChange(of: model.currentNode?.id) { hover = nil }
        .accessibilityLabel("Disk usage treemap")
    }

    // MARK: - Canvas

    private func tileCanvas(tiles: [TreemapTile],
                            selected: Set<UInt64>,
                            cursorID: UInt64?,
                            markedIDs: Set<UInt64>,
                            hoveredID: UInt64?) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            // 1 — fills + hairline borders. Sub-tiles follow their parent in the
            // array, so nesting reads as a slightly deeper wash.
            for tile in tiles {
                let path = Path(tile.rect)
                context.fill(path, with: .color(Color.primary.opacity(Self.fillOpacity(for: tile.tier))))
                context.stroke(path, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
            }
            // 2 — hover wash.
            if let hoveredID, let hovered = tiles.last(where: { $0.id == hoveredID }) {
                context.fill(Path(hovered.rect), with: .color(Color.primary.opacity(0.08)))
            }
            // 3 — mark hatching (diagonal lines, monochrome texture).
            for tile in tiles where markedIDs.contains(tile.id) {
                Self.drawMarkHatch(context, in: tile.rect)
            }
            // 4 — labels.
            for tile in tiles {
                Self.drawLabel(context, tile: tile)
            }
            // 5 — selection / cursor accent strokes on top of everything.
            for tile in tiles where selected.contains(tile.id) || tile.id == cursorID {
                context.stroke(Path(tile.rect.insetBy(dx: 1.5, dy: 1.5)),
                               with: .color(.accentColor), lineWidth: 2.5)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if let tile = tileAt(location) {
                    // Re-render only when the hovered tile changes or the pointer
                    // moved noticeably — not on every mouse-move event.
                    let moved = hover.map { hypot($0.location.x - location.x, $0.location.y - location.y) } ?? .infinity
                    guard hover?.id != tile.id || moved > 24 else { return }
                    hover = HoverReadout(id: tile.id,
                                         name: tile.node.name,
                                         bytes: tile.node.allocatedSize,
                                         tierLabel: tile.tier.label,
                                         location: location)
                } else {
                    hover = nil
                }
            case .ended:
                hover = nil
            }
        }
        .gesture(
            SpatialTapGesture(count: 2)
                .onEnded { value in handleDoubleClick(at: value.location) }
                .exclusively(before: SpatialTapGesture(count: 1)
                    .onEnded { value in handleSingleClick(at: value.location) })
        )
    }

    // MARK: - Empty / loading

    private func emptyState(phase: ScanPhase) -> some View {
        VStack(spacing: 8) {
            Image(systemName: phase == .scanning ? "square.grid.3x3" : "square.dashed")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(phase == .scanning ? "Scanning…" : "No data")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hover readout

    private func readout(_ info: HoverReadout) -> some View {
        HStack(spacing: 8) {
            Text(info.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(Format.bytes(info.bytes))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(info.tierLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: 320)
        .fixedSize()
        .floatingGlassCapsule()
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 1)
    }

    private func readoutOffset(_ info: HoverReadout, in size: CGSize) -> CGSize {
        let estimatedWidth: CGFloat = 260
        let x = min(max(info.location.x + 14, 4), max(4, size.width - estimatedWidth))
        var y = info.location.y + 18
        if y > size.height - 34 { y = info.location.y - 34 }
        return CGSize(width: x, height: max(4, y))
    }

    // MARK: - Interaction

    /// Deepest tile under the point: sub-tiles follow their parent in the
    /// array, so the last hit is the most specific.
    private func tileAt(_ point: CGPoint) -> TreemapTile? {
        var hit: TreemapTile?
        for tile in cache.tiles where tile.rect.contains(point) {
            hit = tile
        }
        return hit
    }

    private func handleSingleClick(at point: CGPoint) {
        guard let tile = tileAt(point) else { return }
        model.setCursor(toNodeID: tile.isSubTile ? tile.topLevelID : tile.node.id)
    }

    private func handleDoubleClick(at point: CGPoint) {
        guard let tile = tileAt(point),
              let top = cache.topLevelByID[tile.topLevelID],
              top.isDirectory else { return }
        model.navigate(to: top)
    }

    // MARK: - Tile computation

    private func cachedTiles(for current: FileNode?,
                             size: CGSize,
                             analyzer: ReclaimAnalyzer?,
                             rowsCount: Int) -> [TreemapTile] {
        guard let current, size.width > 8, size.height > 8 else {
            cache.key = nil
            cache.tiles = []
            cache.topLevelByID = [:]
            return []
        }
        let key = TileCacheKey(nodeID: current.id,
                               width: size.width,
                               height: size.height,
                               rowsCount: rowsCount,
                               allocated: current.allocatedSize,
                               hasAnalyzer: analyzer != nil)
        if cache.key == key { return cache.tiles }
        let built = Self.buildTiles(current: current, size: size, analyzer: analyzer)
        cache.key = key
        cache.tiles = built
        cache.topLevelByID = Dictionary(built.lazy.filter { !$0.isSubTile }.map { ($0.node.id, $0.node) },
                                        uniquingKeysWith: { first, _ in first })
        return built
    }

    /// Pure placement pass: squarified layout of the current node's children,
    /// with one extra level of recursion inside large directory tiles.
    private static func buildTiles(current: FileNode,
                                   size: CGSize,
                                   analyzer: ReclaimAnalyzer?) -> [TreemapTile] {
        let children = current.children
            .filter { $0.allocatedSize > 0 }
            .sorted { $0.allocatedSize > $1.allocatedSize }
        guard !children.isEmpty else { return [] }

        let byID = Dictionary(children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = children.map { TreemapLayout.Item(id: $0.id, weight: Double($0.allocatedSize)) }
        let placements = TreemapLayout.layout(items: items, in: CGRect(origin: .zero, size: size))

        var tiles: [TreemapTile] = []
        tiles.reserveCapacity(placements.count * 4)

        for placement in placements {
            guard let node = byID[placement.id] else { continue }
            let tier = analyzer?.info(for: node).tier ?? .review

            var subTiles: [TreemapTile] = []
            if node.isDirectory, placement.rect.width > 120, placement.rect.height > 80 {
                // Generous margins: sub-tiles never touch their parent's edges.
                var inner = placement.rect.insetBy(dx: 11, dy: 11)
                if placement.rect.width > 60 {
                    // Reserve a band at the top for the directory label, with real
                    // breathing room above and below the text.
                    inner.origin.y += 22
                    inner.size.height -= 22
                }
                if inner.width > 4, inner.height > 4 {
                    let subChildren = node.children
                        .filter { $0.allocatedSize > 0 }
                        .sorted { $0.allocatedSize > $1.allocatedSize }
                        .prefix(256)
                    let subByID = Dictionary(subChildren.map { ($0.id, $0) },
                                             uniquingKeysWith: { first, _ in first })
                    let subItems = subChildren.map { TreemapLayout.Item(id: $0.id, weight: Double($0.allocatedSize)) }
                    for sub in TreemapLayout.layout(items: subItems, in: inner)
                    where sub.rect.width >= 3 && sub.rect.height >= 3 {
                        guard let subNode = subByID[sub.id] else { continue }
                        let subTier = analyzer?.info(for: subNode).tier ?? .review
                        subTiles.append(TreemapTile(node: subNode,
                                                    rect: sub.rect,
                                                    tier: subTier,
                                                    topLevelID: node.id,
                                                    isSubTile: true,
                                                    hasLabelBand: false))
                    }
                }
            }
            tiles.append(TreemapTile(node: node,
                                     rect: placement.rect,
                                     tier: tier,
                                     topLevelID: node.id,
                                     isSubTile: false,
                                     hasLabelBand: !subTiles.isEmpty))
            tiles.append(contentsOf: subTiles)
        }
        return tiles
    }

    // MARK: - Drawing helpers

    /// Brightness encodes safety tier: the safer to delete, the brighter.
    private static func fillOpacity(for tier: SafetyTier) -> Double {
        switch tier {
        case .regenerates: return 0.32
        case .reobtainable: return 0.26
        case .review: return 0.16
        case .coldPersonal: return 0.12
        case .application: return 0.10
        case .protected: return 0.05
        }
    }

    /// Diagonal-line hatch over marked tiles — texture, not hue.
    private static func drawMarkHatch(_ context: GraphicsContext, in rect: CGRect) {
        var layer = context
        layer.clip(to: Path(rect))
        var lines = Path()
        let step = max((rect.width + rect.height) / 5, 4)
        var x = rect.minX - rect.height + step
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        layer.stroke(lines, with: .color(Color.primary.opacity(0.45)), lineWidth: 1)
    }

    private static func drawLabel(_ context: GraphicsContext, tile: TreemapTile) {
        let rect = tile.rect
        if tile.hasLabelBand {
            guard rect.width > 76 else { return }
            let band = CGRect(x: rect.minX + 14, y: rect.minY + 9, width: rect.width - 28, height: 14)
            guard band.width > 8 else { return }
            var layer = context
            layer.clip(to: Path(CGRect(x: rect.minX + 3, y: rect.minY + 3,
                                       width: rect.width - 6, height: 26)))
            let name = layer.resolve(
                Text(tile.node.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85)))
            layer.draw(name, at: CGPoint(x: band.minX, y: band.midY), anchor: .leading)
            let bytes = layer.resolve(
                Text(Format.bytes(tile.node.allocatedSize))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.55)))
            let bounds = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 14)
            if name.measure(in: bounds).width + bytes.measure(in: bounds).width + 12 <= band.width {
                layer.draw(bytes, at: CGPoint(x: band.maxX, y: band.midY), anchor: .trailing)
            }
        } else {
            // Labels only when there's room for real padding — never flush text.
            guard rect.width > 96, rect.height > 34 else { return }
            let inner = rect.insetBy(dx: 13, dy: 10)
            guard inner.width > 8, inner.height > 8 else { return }
            var layer = context
            layer.clip(to: Path(inner))
            let name = layer.resolve(
                Text(tile.node.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85)))
            let bytes = layer.resolve(
                Text(Format.bytes(tile.node.allocatedSize))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.55)))
            if inner.height >= 28 {
                layer.draw(name, at: CGPoint(x: inner.minX, y: inner.minY), anchor: .topLeading)
                layer.draw(bytes, at: CGPoint(x: inner.minX, y: inner.minY + 15), anchor: .topLeading)
            } else {
                layer.draw(name, at: CGPoint(x: inner.minX, y: inner.midY), anchor: .leading)
                let bounds = CGSize(width: CGFloat.greatestFiniteMagnitude, height: inner.height)
                if name.measure(in: bounds).width + bytes.measure(in: bounds).width + 10 <= inner.width {
                    layer.draw(bytes, at: CGPoint(x: inner.maxX, y: inner.midY), anchor: .trailing)
                }
            }
        }
    }
}
