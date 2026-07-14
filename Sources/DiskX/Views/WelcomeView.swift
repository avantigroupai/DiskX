import SwiftUI
import DiskXCore

/// Hero state for first launch (sandboxed builds start here) and scan failures.
/// Monochrome, glass, quiet — sets the tone for the whole app.
struct WelcomeView: View {
    let model: AppModel

    private var failureMessage: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "internaldrive")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
                .padding(28)
                .floatingGlass(cornerRadius: 28)

            VStack(spacing: 6) {
                Text("DiskX")
                    .font(.largeTitle.weight(.semibold))
                Text(failureMessage ?? "See what's eating your disk — and what's safe to delete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            VStack(spacing: 10) {
                if #available(macOS 26.0, *) {
                    Button {
                        model.chooseFolder()
                    } label: {
                        Label("Choose a Location to Scan…", systemImage: "folder")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        model.chooseFolder()
                    } label: {
                        Label("Choose a Location to Scan…", systemImage: "folder")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if !AccessManager.isSandboxed && failureMessage == nil {
                    Button("Scan Home Folder") {
                        model.startScan(path: NSHomeDirectory())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                privacyBadge("lock", "On-device only")
                privacyBadge("eye.slash", "No telemetry")
                privacyBadge("trash", "Trash, never delete")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowWash()
    }

    private func privacyBadge(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
    }
}
