import SwiftUI
import DiskXCore

/// 26pt bottom status bar with three zones:
/// leading — what Delete acts on (or the cursor row's path),
/// center  — disk reconciliation strip,
/// trailing — scan rate / summary + cheat-sheet toggle.
struct StatusBarView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 16) {
                leading(maxPathWidth: geo.size.width * 0.4)
                Spacer(minLength: 8)
                reconciliation
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 26)
    }

    // MARK: - Leading

    @ViewBuilder
    private func leading(maxPathWidth: CGFloat) -> some View {
        if !model.statusSummary.isEmpty {
            Text(model.statusSummary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        } else if let row = model.cursorRow {
            Text(row.node.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxPathWidth, alignment: .leading)
        }
    }

    // MARK: - Center

    private var reconciliation: some View {
        let t = model.truth
        return Text("Scanned \(Format.bytes(t.scannedTotal)) · Other \(Format.bytes(t.otherUsed)) · Purgeable \(Format.bytes(t.purgeable)) · Free \(Format.bytes(t.free))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
    }

    // MARK: - Trailing

    private var trailing: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .scanning:
                Text("\(Format.count(Int64(model.scanRate.rounded()))) files/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                ProgressView()
                    .controlSize(.small)
            case .analyzing:
                Text("Computing reclaim intelligence…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView()
                    .controlSize(.small)
            case .done:
                Text("\(Format.count(model.progress.filesScanned)) files in \(model.scanDuration, specifier: "%.1f")s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            default:
                EmptyView()
            }

            Button {
                model.cheatSheetVisible.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Keyboard shortcuts (?)")
            .accessibilityLabel("Keyboard shortcuts")
        }
    }
}
