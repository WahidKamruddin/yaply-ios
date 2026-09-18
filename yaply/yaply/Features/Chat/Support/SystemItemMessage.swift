import Foundation

/// "Item created" system messages. The decoded text of a `type == "system"`
/// message is JSON `{"v":1,"kind":…,"id":…,"title":…}` so the pill can open
/// the exact item. Mirrors web `src/features/chat/lib/systemItem.ts` — the
/// format must match. Anything that doesn't parse is a legacy plain-text
/// system message (they expire after 7 days).
nonisolated struct SystemItem: Hashable {
    enum Kind: String, CaseIterable {
        case task, note, album, budget, plan, event, reminder

        var noun: String { rawValue }

        /// `ConversationDetailView` tab id.
        var tab: String {
            switch self {
            case .task: "tasks"
            case .note: "notes"
            case .album: "albums"
            case .budget: "budgets"
            case .plan, .event: "events"
            case .reminder: "reminders"
            }
        }

        var symbol: String {
            switch self {
            case .task: "checkmark.square"
            case .note: "note.text"
            case .album: "photo.stack"
            case .budget: "dollarsign.circle"
            case .plan: "map"
            case .event: "calendar"
            case .reminder: "bell"
            }
        }

        /// Tasks and reminders have no detail view — they open the panel tab.
        var opensInPanelOnly: Bool { self == .task || self == .reminder }
    }

    let kind: Kind
    let id: UUID
    let title: String

    /// Same key order as web's `encodeSystemItem`. Built by hand because
    /// JSONEncoder doesn't guarantee key order.
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes // JSON.stringify doesn't escape "/"
        func quote(_ s: String) -> String {
            let data = (try? encoder.encode(s)) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        // Web writes lowercase UUIDs (Postgres' text form); match it.
        return "{\"v\":1,\"kind\":\(quote(kind.rawValue)),\"id\":\(quote(id.uuidString.lowercased())),\"title\":\(quote(title))}"
    }

    static func parse(_ text: String) -> SystemItem? {
        guard text.hasPrefix("{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              (obj["v"] as? Int) == 1,
              let kind = (obj["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let id = (obj["id"] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        return SystemItem(kind: kind, id: id, title: obj["title"] as? String ?? "")
    }

    /// One-line text for places that can't render the pill (list previews).
    static func previewText(_ text: String) -> String {
        guard let item = parse(text) else { return text }
        return "Created a \(item.kind.noun): \(item.title)"
    }
}
