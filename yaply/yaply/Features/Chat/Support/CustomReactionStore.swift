import SwiftUI

/// The user's personalized 6-emoji quick-reaction bar (the Messenger / Instagram
/// long-press rail). Local to this device — persisted in `UserDefaults`, not
/// synced to the account.
@Observable
final class CustomReactionStore {
    static let shared = CustomReactionStore()

    static let defaultSet = ["❤️", "😂", "😮", "😢", "😡", "👍"]

    private let key = "yaply.customReactions.v1"
    private(set) var emojis: [String]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: key)
        emojis = (stored?.count == 6) ? stored! : Self.defaultSet
    }

    /// Replace the emoji in `slot` (0...5). If `emoji` is already in the bar
    /// elsewhere, the two positions swap so the bar never holds a duplicate.
    func replace(slot: Int, with emoji: String) {
        guard emojis.indices.contains(slot), emojis[slot] != emoji else { return }
        var next = emojis
        if let dupe = next.firstIndex(of: emoji) {
            next[dupe] = next[slot]
        }
        next[slot] = emoji
        emojis = next
        UserDefaults.standard.set(next, forKey: key)
    }

    /// Called when the user picks a brand-new emoji from the "+" picker: it takes
    /// the last slot so it's there next time, mirroring Messenger.
    func promote(_ emoji: String) {
        guard !emojis.contains(emoji) else { return }
        replace(slot: 5, with: emoji)
    }

    func reset() {
        emojis = Self.defaultSet
        UserDefaults.standard.removeObject(forKey: key)
    }
}
