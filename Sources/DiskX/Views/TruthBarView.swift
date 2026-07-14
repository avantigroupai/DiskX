import SwiftUI
import DiskXCore

/// The Truth Bar — a 48pt full-width strip under the toolbar.
///
/// Honest byte accounting that reconciles DiskX's scan with what Finder and
/// Storage Settings report (the "System Data mystery"). Left 60% is a stacked
/// capacity bar of `model.truth`; the right side shows the safe-reclaim headline,
/// a ticking "freed this session" counter, and a Full Disk Access chip when the
/// scan hit unreadable folders.
///
/// Mouse interactions only (tooltips + one chip button) — the global key
/// dispatcher owns the keyboard.
struct TruthBarView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stripHeight: CGFloat = 48
    private static let barHeight: CGFloat = 20
    private static let horizontalPadding: CGFloat = 12

    // MARK: - Segments

    private struct Segment: Identifiable {
        enum Style {
            case fill(Double)   // Color.primary at the given opacity
            case hatched        // purgeable: faint fill + 45° hatch lines
            case outline        // free: stroke-only, no fill
        }
        let id: Int
        let label: String
        let bytes: Int64
        let help: String
        let style: Style
        var width: CGFloat = 0
    }

    private var segments: [Segment] {
        let t = model.truth
        let scannedRest = max(0, t.scannedTotal - t.scannedSafe)
        return [
            Segment(id: 0, label: "Reclaimable", bytes: max(0, t.scannedSafe),
                    help: "Safe to delete right now — caches and build artifacts apps rebuild automatically.",
                    style: .fill(0.45)),
            Segment(id: 1, label: "Your scanned files", bytes: scannedRest,
                    help: "Files DiskX scanned in the current target.",
                    style: .fill(0.28)),
            Segment(id: 2, label: "Other & System", bytes: max(0, t.otherUsed),
                    help: "macOS, apps, and areas outside this scan — what Storage Settings calls System Data.",
                    style: .fill(0.15)),
            Segment(id: 3, label: "Purgeable", bytes: max(0, t.purgeable),
                    help: "Space macOS frees automatically when needed (snapshots, offloaded files). Finder counts it as free.",
                    style: .hatched),
            Segment(id: 4, label: "Free", bytes: max(0, t.free),
                    help: "Truly free space.",
                    style: .outline),
        ]
    }

    /// Denominator for proportional widths; falls back to the segment sum
    /// before volume stats exist so the bar never divides by zero.
    private var totalBytes: Int64 {
        let t = model.truth.total
        if t > 0 { return t }
        return segments.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private func barSegments(totalWidth: CGFloat) -> [Segment] {
        let denominator = Double(totalBytes)
        guard denominator > 0, totalWidth > 0 else { return [] }
        return segments.compactMap { segment in
            let width = CGFloat(Double(segment.bytes) / denominator) * totalWidth
            guard width >= 1 else { return nil }   // skip sub-point slivers
            var sized = segment
            sized.width = width
            return sized
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let innerWidth = max(0, geo.size.width - Self.horizontalPadding * 2)
            HStack(alignment: .center, spacing: 12) {
                capacitySection
                    .frame(width: innerWidth * 0.6, alignment: .leading)
                Spacer(minLength: 0)
                reclaimSection
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.stripHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Left: capacity bar + legend

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            capacityBar
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var capacityBar: some View {
        GeometryReader { geo in
            let visible = barSegments(totalWidth: geo.size.width)
            if visible.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            } else {
                HStack(spacing: 0) {
                    ForEach(visible) { segment in
                        segmentSwatch(segment.style)
                            .frame(width: segment.width)
                            .help(segment.help)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.truth.scannedTotal)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.truth.scannedSafe)
            }
        }
        .frame(height: Self.barHeight)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(segments.filter { $0.bytes > 0 }) { segment in
                HStack(spacing: 4) {
                    segmentSwatch(segment.style)
                        .frame(width: 8, height: 8)
                    Text(segment.label)
                    Text(Format.bytes(segment.bytes))
                        .monospacedDigit()
                }
                .help(segment.help)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func segmentSwatch(_ style: Segment.Style) -> some View {
        switch style {
        case .fill(let opacity):
            Rectangle()
                .fill(Color.primary.opacity(opacity))
        case .hatched:
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .overlay(hatchLines)
        case .outline:
            Rectangle()
                .strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5)
        }
    }

    /// 45° diagonal hatch — the visual convention for "purgeable" space.
    private var hatchLines: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let spacing: CGFloat = 4
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private var accessibilitySummary: String {
        let parts = segments.filter { $0.bytes > 0 }
            .map { "\($0.label) \(Format.bytes($0.bytes))" }
        return parts.isEmpty ? "Disk capacity: no data yet" : "Disk capacity: " + parts.joined(separator: ", ")
    }

    // MARK: - Right: reclaim headline, session counter, FDA chip

    private var reclaimSection: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Reclaimable now: ~\(Format.bytes(model.truth.scannedSafe)) safe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            Text("Freed this session: \(Format.bytes(model.freedThisSession))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .default, value: model.freedThisSession)

            if model.progress.deniedDirs > 0 {
                fullDiskAccessChip
            }
        }
        .lineLimit(1)
    }

    private var fullDiskAccessChip: some View {
        Button {
            model.openFullDiskAccessSettings()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "lock")
                    .font(.system(size: 9, weight: .medium))
                Text("(\(model.progress.deniedDirs)) folders unreadable — grant Full Disk Access")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Some folders could not be read. Grant DiskX Full Disk Access in System Settings → Privacy & Security for a complete scan.")
    }
}
