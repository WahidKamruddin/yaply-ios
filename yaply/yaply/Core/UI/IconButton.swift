import SwiftUI

/// Icon-only button with a 44x44pt hit area (Apple's minimum), press feedback
/// and a required VoiceOver label. The glyph keeps its own size; only the
/// tappable region grows, so swapping a bare `Button` for this doesn't change
/// how a screen looks.
struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 18
    var weight: Font.Weight = .medium
    var color: Color = .yaplySecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(YaplyPressStyle())
        .accessibilityLabel(label)
    }
}
