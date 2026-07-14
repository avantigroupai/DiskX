import SwiftUI

/// Full-window keyboard cheat sheet. Dismissal: Esc and `?` are handled globally
/// (KeyboardDispatch); a click anywhere also closes it. Content mirrors the
/// bindings in KeyboardDispatch.swift — keep the two in sync.
struct CheatSheetView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            card
        }
        .contentShape(Rectangle())
        .onTapGesture { model.cheatSheetVisible = false }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Keyboard shortcuts")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 22) {
                group("Navigate", Self.navigate)
                group("Select & Mark", Self.selectMark)
                group("Act", Self.act)
                group("Sort & View", Self.sortView)
            }
        }
        .padding(24)
        .frame(maxWidth: 640)
        .floatingGlass(cornerRadius: 16)
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        .padding(32)
    }

    private func group(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            ForEach(shortcuts) { shortcut in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(shortcut.keys, id: \.self) { Keycap(label: $0) }
                    }
                    Text(shortcut.what)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Data (mirrors KeyboardDispatch.swift)

    private struct Shortcut: Identifiable {
        let keys: [String]
        let what: String
        var id: String { keys.joined() + what }
        init(_ keys: [String], _ what: String) {
            self.keys = keys
            self.what = what
        }
    }

    private static let navigate: [Shortcut] = [
        Shortcut(["↑ ↓", "J K"], "Move"),
        Shortcut(["→", "L", "⏎"], "Open"),
        Shortcut(["←", "H"], "Up"),
        Shortcut(["⌘ ↑"], "Parent"),
        Shortcut(["⎋"], "Back"),
    ]

    private static let selectMark: [Shortcut] = [
        Shortcut(["⇧ ↑ ↓"], "Extend selection"),
        Shortcut(["⌘ A"], "Select all"),
        Shortcut(["X"], "Mark"),
        Shortcut(["⇧ X"], "Clear marks"),
    ]

    private static let act: [Shortcut] = [
        Shortcut(["⌫", "D"], "Delete"),
        Shortcut(["⏎", "Y"], "Confirm"),
        Shortcut(["⎋", "N"], "Cancel"),
        Shortcut(["⌘ Z"], "Undo"),
        Shortcut(["Space"], "Preview"),
        Shortcut(["E"], "Reveal in Finder"),
        Shortcut(["I"], "Inspector"),
    ]

    private static let sortView: [Shortcut] = [
        Shortcut(["1 – 5"], "Sorts"),
        Shortcut(["S"], "Cycle sort"),
        Shortcut(["`"], "Top files"),
        Shortcut(["G"], "Goal"),
        Shortcut(["/"], "Search"),
        Shortcut(["?"], "This sheet"),
        Shortcut(["P"], "Pause scan"),
    ]
}

/// A single monochrome "keycap": monospaced caption on a 4pt-rounded quaternary chip.
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption)
            .fontDesign(.monospaced)
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
            )
    }
}
