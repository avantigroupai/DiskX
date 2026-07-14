import SwiftUI
import DiskXCore

/// Left sidebar: scan targets, smart scopes, and bottom-pinned scan mini-stats.
/// Keyboard is handled globally (KeyboardDispatch); this view is mouse-only.
struct SidebarView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Scan") {
                ForEach(model.scanTargets) { target in
                    SidebarRowButton(symbolName: target.symbolName,
                                     title: target.name,
                                     isActive: target.path == model.scanTargetPath) {
                        model.startScan(path: target.path)
                    }
                    .listRowBackground(rowHighlight(target.path == model.scanTargetPath))
                }
                SidebarRowButton(symbolName: "folder.badge.plus",
                                 title: "Choose Folder…",
                                 isActive: false) {
                    model.chooseFolder()
                }
                .listRowBackground(rowHighlight(false))
            }

            Section("Smart Scopes") {
                ForEach(SmartScope.allCases) { scope in
                    SidebarRowButton(symbolName: scope.symbolName,
                                     title: scope.rawValue,
                                     isActive: model.scope == scope) {
                        model.scope = (model.scope == scope ? nil : scope)
                    }
                    .disabled(model.phase != .done)
                    .opacity(model.phase == .done ? 1 : 0.4)
                    .listRowBackground(rowHighlight(model.scope == scope))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let root = model.root {
                VStack(spacing: 0) {
                    Divider()
                    Text("\(Format.count(root.fileCount)) files · \(Format.bytes(root.allocatedSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
    }

    /// Accent is reserved for selection/active states; 0.12 keeps it a whisper.
    private func rowHighlight(_ isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor.opacity(isActive ? 0.12 : 0))
            .padding(.horizontal, 4)
    }
}

/// One sidebar row: monochrome 13pt glyph + label. Plain button so `.disabled` works.
private struct SidebarRowButton: View {
    let symbolName: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
