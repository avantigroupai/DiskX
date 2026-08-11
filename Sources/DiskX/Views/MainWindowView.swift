import SwiftUI
import AppKit
import DiskXCore

/// The window shell: sidebar, Truth Bar, and the list/treemap panes.
///
/// It also owns the local `NSEvent` monitor that feeds `AppModel.handleKey`. The
/// monitor lives here rather than in the model because its lifetime has to match
/// the window's — leaving it installed after the window closes would keep routing
/// keystrokes into a detached model.
struct MainWindowView: View {
    @Bindable var model: AppModel
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if model.root == nil && (model.phase == .idle || isFailed) {
                WelcomeView(model: model)
            } else {
                VStack(spacing: 10) {
                    TruthBarView(model: model)
                        .floatingGlass(cornerRadius: 12)
                    contentPanes
                    StatusBarView(model: model)
                        .floatingGlass(cornerRadius: 10)
                }
                .padding(12)
                .windowWash()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar { toolbarContent }
        .overlay(alignment: .top) {
            if model.goalActive {
                GoalOverlay(model: model)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if model.cheatSheetVisible {
                CheatSheetView(model: model)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(message: toast)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: model.toast != nil)
        .animation(.spring(duration: 0.2), value: model.goalActive)
        .sheet(item: $model.pendingDelete) { plan in
            ConfirmSheet(model: model, plan: plan)
        }
        .onAppear {
            installKeyMonitor()
            (AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "") ?? .system).apply()
            if model.phase == .idle, let path = model.autoScanPath {
                model.startScan(path: path)
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var contentPanes: some View {
        switch model.viewMode {
        case .both:
            // Cards float with a 10pt gutter; the split divider lives in the gap.
            HSplitView {
                FileListView(model: model)
                    .paneCard()
                    .frame(minWidth: 360)
                    .layoutPriority(1)
                    .padding(.trailing, 5)
                TreemapView(model: model)
                    .paneCard()
                    .frame(minWidth: 300)
                    .padding(.leading, 5)
            }
        case .list:
            FileListView(model: model)
                .paneCard()
        case .map:
            VStack(spacing: 0) {
                FileListBreadcrumbOnly(model: model)
                TreemapView(model: model)
            }
            .paneCard()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            scanControl
        }
        ToolbarItemGroup {
            Picker("Sort", selection: sortBinding) {
                ForEach(SortMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Sort — keys 1–5, S cycles")

            Picker("View", selection: viewBinding) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.symbolName).tag(mode)
                        .help(mode.label)
                }
            }
            .pickerStyle(.segmented)

            SearchField(model: model)
        }
    }

    private var sortBinding: Binding<SortMode> {
        Binding(get: { model.sortMode }, set: { model.selectSort($0) })
    }

    private var viewBinding: Binding<ViewMode> {
        Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
    }

    @ViewBuilder
    private var scanControl: some View {
        if model.phase == .scanning {
            Button {
                model.cancelScan()
            } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(Format.count(model.progress.filesScanned)) files · \(Format.bytes(model.progress.bytesFound))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "stop.circle")
                }
            }
            .help("Stop scan (P)")
        } else {
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Rescan (⌘R)")
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept keys for our own key window (not panels, open dialogs…).
            guard let window = event.window,
                  window.isKeyWindow,
                  !(window is NSPanel) else { return event }
            return model.handleKey(event) ? nil : event
        }
    }
}

/// Thin breadcrumb strip used when the map is full-window.
struct FileListBreadcrumbOnly: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.navigate(to: node)
                } label: {
                    Text(node.name == "/" ? "Macintosh HD" : (node.name as NSString).lastPathComponent)
                        .font(.callout)
                        .fontWeight(index == model.breadcrumb.count - 1 ? .semibold : .regular)
                        .foregroundStyle(index == model.breadcrumb.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Toolbar search field; `/` focuses it via the global dispatcher's notification.
struct SearchField: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 140)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        .onReceive(NotificationCenter.default.publisher(for: .diskxFocusSearch)) { _ in
            focused = true
        }
        .help("Filter names (/) — Esc clears")
    }
}
