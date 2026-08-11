import SwiftUI
import AppKit
import DiskXCore

/// The Reclaim List — the app's primary pane and keyboard home.
///
/// A custom row list (ScrollView + LazyVStack) over `model.rows`. All keyboard
/// handling lives in `AppModel.handleKey` (global NSEvent monitor); this view
/// implements mouse interactions only.
@MainActor
struct FileListView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Row ids currently materialized on screen (approximate, via LazyVStack
    /// appear/disappear). Used to avoid re-centering on every j/k step.
    @State private var visibleRowIDs: Set<UInt64> = []

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(model: model)
            Divider()
            // The scroll view spans the full pane so the scroll bar sits at the card
            // edge (macOS convention); row content carries its own insets instead.
            listBody
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if model.rows.isEmpty && model.phase == .done {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            FileRowView(row: row,
                                        index: index,
                                        isCursor: index == model.cursor,
                                        isSelected: model.selectedIDs.contains(row.id),
                                        isMarked: model.marks[row.id] != nil,
                                        model: model)
                                .id(row.id)
                                .onAppear { visibleRowIDs.insert(row.id) }
                                .onDisappear { visibleRowIDs.remove(row.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: model.cursor) { _, newCursor in
                    guard model.rows.indices.contains(newCursor) else { return }
                    let id = model.rows[newCursor].id
                    // Only scroll when the cursor row left the visible band.
                    guard !visibleRowIDs.contains(id) else { return }
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing here")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Breadcrumb bar

@MainActor
private struct BreadcrumbBar: View {
    let model: AppModel

    var body: some View {
        let crumbs = model.breadcrumb
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        if index == crumbs.count - 1 {
                            Text(displayName(node))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .id(node.id)
                        } else {
                            Button {
                                model.navigate(to: node)
                            } label: {
                                Text(displayName(node))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .id(node.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 28)
            .onChange(of: crumbs.last?.id) { _, lastID in
                if let lastID {
                    proxy.scrollTo(lastID, anchor: .trailing)
                }
            }
        }
    }

    /// Root nodes carry the whole scan path as their name — show only the tail.
    private func displayName(_ node: FileNode) -> String {
        if node.parent == nil {
            let tail = (node.name as NSString).lastPathComponent
            return tail.isEmpty ? node.name : tail
        }
        return node.name
    }
}

// MARK: - Row

@MainActor
private struct FileRowView: View {
    let row: Row
    let index: Int
    let isCursor: Bool
    let isSelected: Bool
    let isMarked: Bool
    let model: AppModel

    private var kindSymbol: String {
        if row.node.isPackage { return "shippingbox" }
        if row.node.isDirectory { return "folder" }
        return row.category.symbolName
    }

    private var rowOpacity: Double {
        if row.tier == .protected { return 0.45 }   // protected: whole row recedes
        if isMarked { return 0.6 }                  // marked: dimmed, queued for delete
        return 1.0
    }

    var body: some View {
        HStack(spacing: 8) {
            markMargin
            Image(systemName: kindSymbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.isGhost ? "↳ \(row.node.name)" : row.node.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.isGhost ? row.ghostSuffix : row.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            Image(systemName: row.tier.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(row.tier.label)

            Text(row.ageText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(row.primaryBytes))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if row.node.isDirectory {
                    Text(Format.count(row.node.fileCount) + " files")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Extra trailing room so the size column never collides with the overlay
        // scroll bar, which floats above the content on macOS.
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .frame(height: 44)
        .background(alignment: .leading) { proportionalBar }
        .background(selectionColor)
        .overlay(alignment: .leading) {
            if isCursor {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .opacity(rowOpacity)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded {
            model.moveCursorTo(index)
            model.descend()
        })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            handleSingleClick()
        })
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    private var markMargin: some View {
        ZStack {
            if isMarked {
                Image(systemName: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }

    /// Size bar behind the row: full segment = share of the largest row,
    /// darker inner segment = the reclaimable share of this row's own size.
    private var proportionalBar: some View {
        GeometryReader { geo in
            let barWidth = max(0, geo.size.width * row.barFraction)
            let safeWidth = max(0, barWidth * row.safeFraction)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: barWidth)
                if safeWidth >= 1 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: safeWidth)
                }
            }
            .padding(.vertical, 5)
        }
        .allowsHitTesting(false)
    }

    private var selectionColor: Color {
        if isCursor { return Color.accentColor.opacity(0.18) }
        if isSelected { return Color.accentColor.opacity(0.10) }
        return .clear
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        // Item actions operate on the cursor row, so aim the cursor first.
        Button("Reveal in Finder") {
            model.moveCursorTo(index)
            model.revealInFinder()
        }
        Button("Open") {
            model.moveCursorTo(index)
            model.openSelection()
        }
        Button("Copy Path") {
            model.moveCursorTo(index)
            model.copyPath()
        }
        Button(isMarked ? "Unmark (X)" : "Mark (X)") {
            model.toggleMark(row.node)
        }
        Divider()
        Button("Move to Trash (⌫)") {
            model.moveCursorTo(index)
            // Scope to the clicked row — background marks must not ride along.
            model.requestDelete(only: row.node)
        }
    }

    // MARK: Mouse

    private func handleSingleClick() {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if model.selectedIDs.contains(row.id) {
                model.selectedIDs.remove(row.id)
            } else {
                model.selectedIDs.insert(row.id)
            }
            model.cursor = index
        } else if mods.contains(.shift) {
            model.moveCursor(index - model.cursor, extending: true)
        } else {
            model.moveCursorTo(index)
        }
    }
}
