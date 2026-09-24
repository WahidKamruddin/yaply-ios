import SwiftUI

// Press feedback for controls that would otherwise use `.buttonStyle(.plain)`
// and give no visual response. Mirrors the web's `active:scale-95` /
// `active:bg-tint-strong` treatment.

/// Small controls (icon buttons, send): slight shrink + dim while pressed.
struct YaplyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// List rows: highlight the row with the strong tint while pressed.
struct YaplyRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.yaplyTintStrong : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// `withAnimation`-style value animation that collapses to none when the
    /// user has Reduce Motion enabled.
    func yaplyAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(YaplyReduceMotionAnimation(animation: animation, value: value))
    }
}

private struct YaplyReduceMotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
