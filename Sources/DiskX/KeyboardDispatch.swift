import AppKit
import SwiftUI

/// Bare-key routing per spec §5. Installed as a local NSEvent monitor; returns true
/// when the event was consumed. Philosophy: 100% of the app works without a mouse.
extension AppModel {
    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)

        // Key codes for non-character keys.
        let kReturn: UInt16 = 36, kEscape: UInt16 = 53, kDelete: UInt16 = 51, kForwardDelete: UInt16 = 117
        let kUp: UInt16 = 126, kDown: UInt16 = 125, kLeft: UInt16 = 123, kRight: UInt16 = 124
        let kHome: UInt16 = 115, kEnd: UInt16 = 119, kSpace: UInt16 = 49

        // 1 — Confirm sheet: Return/Y confirm (Return inert when risky), Esc/N cancel.
        if let plan = pendingDelete {
            switch true {
            case code == kReturn && !plan.risky:
                confirmDelete(); return true
            case code == kReturn && plan.risky:
                return true      // deliberately inert — Y required (spec §7.3)
            case key == "y" && !cmd:
                confirmDelete(); return true
            case code == kEscape || (key == "n" && !cmd):
                cancelDelete(); return true
            case code == kSpace:
                if let first = plan.items.first {
                    QuickLookController.shared.toggle(urls: plan.items.map(\.url))
                    _ = first
                }
                return true
            default:
                return false     // Tab & arrows keep native sheet behavior
            }
        }

        // 2 — Cheat sheet overlay.
        if cheatSheetVisible {
            if code == kEscape || key == "?" { cheatSheetVisible = false; return true }
            return false
        }

        // 3 — Goal overlay: Return applies (overlay stays up to show the result),
        // Esc dismisses; typing passes through. 76 = keypad Enter.
        if goalActive {
            if code == kReturn || code == 76 { applyGoal(); return true }
            if code == kEscape { goalActive = false; return true }
            return false
        }

        // 4 — While a text field is focused only Esc is intercepted.
        if isEditingText {
            if code == kEscape {
                searchText = ""
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        // 5 — Command keys: row-scoped ⌘↑/⌘A/⌘C here (text fields are already ruled
        // out above, so the system Edit menu keeps working while editing); the rest
        // fall through to the menu bar.
        if cmd {
            if code == kUp { ascend(); return true }
            if key == "a" && !shift && !option { selectAll(); return true }
            if key == "c" && !shift && !option { copyPath(); return true }
            return false
        }

        // 6 — Main keyboard map.
        switch true {
        case option && code == kUp:
            moveCursor(-12, extending: shift); return true
        case option && code == kDown:
            moveCursor(12, extending: shift); return true
        case code == kUp || key == "k":
            moveCursor(-1, extending: shift); return true
        case code == kDown || key == "j":
            moveCursor(1, extending: shift); return true
        case code == kRight || key == "l" || code == kReturn:
            descend(); return true
        case code == kLeft || key == "h":
            ascend(); return true
        case code == kHome:
            moveCursorTo(0); return true
        case code == kEnd:
            moveCursorTo(rows.count - 1); return true
        case code == kSpace:
            quickLook(); return true
        case key == "x" && shift:
            clearMarks(); return true
        case key == "x":
            toggleMarkAtCursor(); return true
        case code == kDelete || code == kForwardDelete || key == "d":
            requestDelete(); return true
        case key == "e":
            revealInFinder(); return true
        case key == "i":
            inspectorVisible.toggle(); return true
        case key == "g":
            goalActive = true; return true
        case key == "s":
            cycleSort(); return true
        case key == "1": selectSort(.reclaim); return true
        case key == "2": selectSort(.size); return true
        case key == "3": selectSort(.forgotten); return true
        case key == "4": selectSort(.count); return true
        case key == "5": selectSort(.name); return true
        case key == "`":
            scope = nil
            flatTop.toggle(); return true
        case key == "/":
            NotificationCenter.default.post(name: .diskxFocusSearch, object: nil); return true
        case key == "?":
            cheatSheetVisible = true; return true
        case key == "p":
            if phase == .scanning { cancelScan() }; return true
        case code == kEscape:
            clearSelectionOrAscend(); return true
        default:
            return false
        }
    }
}

extension Notification.Name {
    /// Posted when a bare keystroke should move focus into the search field. The
    /// dispatcher runs above the view tree and has no reference to the field, so
    /// this is the one hop back down.
    static let diskxFocusSearch = Notification.Name("diskxFocusSearch")
}
