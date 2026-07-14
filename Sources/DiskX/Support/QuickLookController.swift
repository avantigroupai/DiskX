import AppKit
import Quartz

/// Bridges DiskX to the shared Quick Look panel (`QLPreviewPanel`).
///
/// DiskX is not an NSDocument app, so instead of the classic responder-chain
/// handshake (`acceptsPreviewPanelControl` / `beginPreviewPanelControl`) this
/// controller claims the panel directly: `toggle(urls:)` re-assigns the panel's
/// `dataSource` and `delegate` on every presentation. The panel re-resolves its
/// controller from the responder chain whenever key windows change — which can
/// null these out in a non-document app — so setting them again each time keeps
/// the callbacks wired no matter what happened in between.
///
/// Arrow keys inside the panel page through the stored URLs natively: the panel
/// drives the flipping itself through `QLPreviewPanelDataSource`, no key
/// handling is needed here (and none is installed — the app's global keyboard
/// dispatch lives in `KeyboardDispatch.swift`).
@MainActor
final class QuickLookController: NSObject {
    static let shared = QuickLookController()

    /// Items currently offered to the panel.
    private var urls: [URL] = []

    /// Shows the panel previewing `urls`, or closes it if it is already up.
    func toggle(urls: [URL]) {
        self.urls = urls

        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(),
           panel.isVisible {
            panel.orderOut(nil)
            return
        }

        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - QLPreviewPanelDataSource

/// The panel calls back on the main thread; the witnesses are `nonisolated`
/// to satisfy the (unannotated) ObjC protocol and hop back onto the main
/// actor to read `urls`.
extension QuickLookController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let item: NSURL? = MainActor.assumeIsolated {
            guard urls.indices.contains(index) else { return nil }
            return urls[index] as NSURL
        }
        return item
    }
}

// MARK: - QLPreviewPanelDelegate

extension QuickLookController: QLPreviewPanelDelegate {
    /// Returning `false` keeps the panel's default key behavior:
    /// Space closes the panel, ← / → flip through the data-source items.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
