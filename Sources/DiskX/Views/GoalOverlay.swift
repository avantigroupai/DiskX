import SwiftUI
import DiskXCore

/// Floating "I need N GB back" card, pinned top-center. Return applies and Esc
/// dismisses via the global key monitor (KeyboardDispatch); `.onSubmit` covers
/// submission while the field itself holds focus.
struct GoalOverlay: View {
    @Bindable var model: AppModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("I need")
                TextField("25", text: $model.goalInput)
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .focused($fieldFocused)
                    .onSubmit { model.applyGoal() }
                Text("GB back")
            }
            .font(.body)

            if let result = model.goalResult {
                if result.count == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.slash")
                            .foregroundStyle(.secondary)
                        Text("No safe items found — try a smaller goal")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.primary)
                        Text("These \(result.count) items get you \(Format.bytes(result.bytes)) — all safe, marked for deletion. Press ⌫ to review.")
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 16)
        .onAppear { fieldFocused = true }
        .accessibilityLabel("Free-space goal")
    }
}
