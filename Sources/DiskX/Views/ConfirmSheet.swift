import SwiftUI
import DiskXCore

/// The deletion confirmation sheet — the app's signature safety moment (spec §7).
///
/// Presented by `MainWindowView` while `model.pendingDelete` is non-nil.
/// Keyboard handling (Return/Y confirm, Esc/N cancel, Space quick-look) lives in
/// the GLOBAL dispatcher (`KeyboardDispatch.swift`) — this view installs no key
/// handlers of its own; its buttons exist for mouse users and mirror the same
/// `confirmDelete()` / `cancelDelete()` calls.
struct ConfirmSheet: View {
    let model: AppModel
    let plan: DeletePlan

    private var titleText: String {
        let n = plan.items.count
        return n == 1 ? "Move 1 item to Trash?" : "Move \(n) items to Trash?"
    }

    private var allRegenerate: Bool {
        plan.safeBytes == plan.totalBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            itemList
            if !plan.excludedProtected.isEmpty {
                protectedSection
            }
            footer
        }
        .padding(20)
        .frame(width: 460)
        .frame(maxHeight: 520)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            // Honest math: what actually frees when the Trash empties.
            Text("Frees about \(Format.bytes(plan.totalBytes)) now.")
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if allRegenerate {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 11))
                    Text("All of these regenerate — apps rebuild them automatically.")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }

            if let reason = plan.riskReason {
                // Deliberately monochrome: weight and symbol carry the warning, not hue.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(reason)
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }

            ForEach(plan.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Item list

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(plan.items) { node in
                    ConfirmItemRow(node: node,
                                   tierSymbolName: model.analyzer?.info(for: node).tier.symbolName)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 150)   // ~5 rows of 30pt
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Protected section

    private var protectedSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Cannot be trashed (system)")
                .font(.caption.weight(.medium))
            ForEach(plan.excludedProtected) { node in
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 10))
                        .frame(width: 14)
                    Text(node.name)
                        .font(.caption)
                        .lineLimit(1)
                    Text(node.path)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .foregroundStyle(.primary)
        .opacity(0.45)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Spacer()
                if plan.risky {
                    // Risky: the destructive button loses prominence, Cancel gains it.
                    Button("Cancel") { model.cancelDelete() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash") { model.confirmDelete() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Cancel") { model.cancelDelete() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash") { model.confirmDelete() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(model.isTrashing)

            VStack(alignment: .trailing, spacing: 2) {
                if plan.risky {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 11))
                        Text("Press Y to confirm — Return is disabled for risky deletes · Esc or N to cancel")
                    }
                } else {
                    Text("Return or Y to confirm · Esc or N to cancel")
                }
                Text("Space previews the items")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Item row

/// One 30pt row in the confirmation list: kind glyph, name, middle-truncated
/// path, right-aligned allocated size, and the safety-tier badge.
private struct ConfirmItemRow: View {
    let node: FileNode
    let tierSymbolName: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(node.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(Format.bytes(node.allocatedSize))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Image(systemName: tierSymbolName ?? "circle.dashed")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .opacity(tierSymbolName == nil ? 0 : 1)   // keeps sizes column aligned pre-analysis
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

// MARK: - Toast

/// Bottom-center floating confirmation capsule.
///
/// Intended usage from the window chrome:
/// ```
/// if let toast = model.toast {
///     ToastView(message: toast)
///         .transition(.move(edge: .bottom).combined(with: .opacity))
/// }
/// ```
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8)
    }
}
