import SwiftUI

/// Liquid Glass adoption (macOS 26+) with graceful material fallbacks, following
/// Apple's guidance: real glass for floating chrome (overlays, toasts, readouts),
/// quiet inset material cards for large content panes.
extension View {
    /// Content-pane treatment: a floating rounded card over the window wash —
    /// the Tahoe inset-pane look. Not glass: large scrolling content should sit
    /// on a calm surface, with glass reserved for chrome above it.
    func paneCard(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
    }

    /// Floating chrome: real Liquid Glass on macOS 26+, regular material below.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular,
                             in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        }
    }

    /// Capsule variant for pill-shaped chrome (toasts, hover readouts).
    @ViewBuilder
    func floatingGlassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
    }

    /// The window wash the floating panes sit on.
    func windowWash() -> some View {
        self.background(Color(nsColor: .underPageBackgroundColor))
    }
}
