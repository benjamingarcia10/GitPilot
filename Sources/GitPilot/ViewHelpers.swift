import SwiftUI

// MARK: - Hover highlight modifier

/// Adds a subtle hover background so the user can see what's clickable.
/// Works in both light and dark mode by using a primary-color tint with low opacity.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 5) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

// MARK: - Hoverable button style

/// Borderless-style button that adds a hover background and a press-state dim,
/// so action buttons (Rebase / Open / Refresh / etc.) feel responsive on Mac.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonContent(configuration: configuration)
    }
}

private struct HoverButtonContent: View {
    let configuration: HoverButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundFill)
            )
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var backgroundFill: Color {
        if configuration.isPressed { return Color.primary.opacity(0.15) }
        if hovering { return Color.primary.opacity(0.10) }
        return Color.clear
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}
