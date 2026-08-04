import SwiftUI

// Shared "card" treatment for the productivity list screens (Tasks, Notes,
// Reminders, Events, Albums, Budgets) so each floats as an elevated card
// over yaplyBackground instead of a flat default List row — matching the
// web app's card aesthetic. Applied to row *content* inside a plain List
// (with row chrome hidden) so native .swipeActions keep working unchanged;
// no custom gesture code needed to get the card look.
extension View {
    func yaplyCardStyle() -> some View {
        self
            .padding(14)
            .background(Color.yaplyCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder, lineWidth: 1))
    }

    /// Hides native List row chrome (background/separator/insets) so a
    /// `.yaplyCardStyle()`-wrapped row can float with its own spacing,
    /// corner radius, and border instead of looking like a default List row.
    func yaplyCardRowContainer() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// Shared empty-state view for productivity list screens: an icon, a
/// caption, and an optional call-to-action button.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Color.yaplySecondary)
            Text(title)
                .foregroundStyle(Color.yaplySecondary)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.subheadline)
                    .foregroundStyle(Color.yaplyAccent)
            }
        }
    }
}
