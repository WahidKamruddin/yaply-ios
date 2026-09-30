import SwiftUI

/// The user's selected chat visual style — yaply's own look, or a
/// Messenger/iMessage-inspired skin. Selected in Settings -> Account, and
/// read by Color+Yaply, Font+Yaply, BubbleGeometry, NavChrome, and the
/// reaction/composer/nav-header rendering in the chat views so every screen
/// restyles together. UI-only: no feature/behavior differs between styles.
enum ChatStyle: String, CaseIterable, Identifiable {
    case yaply, messenger, imessage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yaply: return "yaply"
        case .messenger: return "Messenger"
        case .imessage: return "iMessage"
        }
    }

    /// Each style's own accent color, regardless of which style is
    /// currently active — unlike `Color.yaplyAccent` (which always reflects
    /// `.current`), this is for previewing an option in the Settings picker
    /// before it's selected. Kept in sync with `Color.yaplyAccent`'s
    /// per-style values in Color+Yaply.swift.
    var accentPreview: Color {
        switch self {
        case .yaply: return Color(red: 0.357, green: 0.553, blue: 0.937)
        case .messenger: return Color(red: 0.000, green: 0.518, blue: 1.000)
        case .imessage: return Color(red: 0.043, green: 0.576, blue: 0.965)
        }
    }

    static let storageKey = "chatStyle"

    /// Reads the persisted preference directly, for use in static
    /// Color/Font/geometry helpers that aren't Views and so can't hold an
    /// `@AppStorage` binding themselves. `ContentView` holds the real
    /// `@AppStorage("chatStyle")` binding and applies `.id(chatStyle)` to
    /// the root view so a change here re-evaluates the whole tree fresh.
    static var current: ChatStyle {
        ChatStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .yaply
    }
}
