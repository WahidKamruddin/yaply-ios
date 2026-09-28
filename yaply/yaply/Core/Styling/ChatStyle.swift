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
