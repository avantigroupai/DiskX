import SwiftUI
import DiskXCore

@main
struct DiskXApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainWindowView(model: model)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                Divider()
                Button(model.phase == .scanning ? "Stop Scan" : "Scan Home") {
                    if model.phase == .scanning {
                        model.cancelScan()
                    } else {
                        model.startScan(path: NSHomeDirectory())
                    }
                }
                .keyboardShortcut(".")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move to Trash") { model.undoLastTrash() }
                    .keyboardShortcut("z")
                    .disabled(model.undoStack.isEmpty)
            }
            // Standard Edit items stay intact for text fields; row-scoped ⌘A/⌘C are
            // handled by the key dispatcher when no field is focused.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Path") { model.copyPath() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") { model.ascend() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Reveal in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open") { model.openSelection() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Sort") {
                ForEach(SortMode.allCases) { mode in
                    Button(mode.label) { model.selectSort(mode) }
                }
                Divider()
                Button("Top Files (flat)") { model.flatTop.toggle() }
                    .keyboardShortcut("t")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.cheatSheetVisible = true }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }
    }
}
