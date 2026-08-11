import SwiftUI
import AppKit

/// App-wide appearance: follow the system, or pin light/dark.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appTheme"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The ⌘, settings pane. Appearance only — DiskX has no accounts, no telemetry
/// toggles and nothing to configure about scanning.
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.label, systemImage: theme.symbolName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: themeRaw) { _, raw in
                    (AppTheme(rawValue: raw) ?? .system).apply()
                }
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $model.showHidden)
            }
            Section("Privacy") {
                LabeledContent("Telemetry") { Text("None — DiskX never phones home").foregroundStyle(.secondary) }
                LabeledContent("Analysis") { Text("Entirely on-device").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
