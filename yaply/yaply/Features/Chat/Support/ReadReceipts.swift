import Foundation

/// One member's read and delivery watermarks: every message created at or before
/// them has been read / delivered by that member (conversation_members
/// .last_read_at / .last_delivered_at). Nothing is stored per message.
nonisolated struct MemberWatermark: Equatable, Sendable {
    var readAt: Date?
    var deliveredAt: Date?
}

/// Messenger-style read receipts, derived from watermarks.
///
/// Swift port of web's `src/features/chat/lib/readReceipts.ts` — the two must
/// agree rule for rule (see ../CLAUDE.md "Read receipts (watermarks)").
nonisolated enum ReadReceipts {
    enum Status: Equatable {
        case sending
        case sent
        case delivered
        case seen(readerIds: [UUID], everyone: Bool)
    }

    /// Sending a message implies having read everything up to it, so a member's
    /// effective read (and delivery) watermark is at least their own latest sent
    /// message. Apply before `seenHeads` / `status`.
    static func withImpliedReads(
        messages: [DecryptedMessage],
        watermarks: [UUID: MemberWatermark],
        pendingIds: Set<UUID>
    ) -> [UUID: MemberWatermark] {
        var lastSent: [UUID: Date] = [:]
        for m in messages where m.type != "system" && !pendingIds.contains(m.id) {
            guard let sender = m.senderId else { continue }
            if lastSent[sender].map({ m.createdAt > $0 }) ?? true { lastSent[sender] = m.createdAt }
        }
        var adjusted = watermarks
        for (userId, mark) in watermarks {
            guard let sent = lastSent[userId] else { continue }
            adjusted[userId] = MemberWatermark(
                readAt: max(mark.readAt ?? .distantPast, sent),
                deliveredAt: max(mark.deliveredAt ?? .distantPast, sent)
            )
        }
        return adjusted
    }

    /// Where each other member's "seen" avatar sits: under the newest loaded,
    /// non-system, non-pending message at or before their read watermark — where
    /// they left off. Pass watermarks through `withImpliedReads` first, so a
    /// member who has since sent a message sits at (or after) their own message.
    /// `messages` is oldest-first.
    static func seenHeads(
        messages: [DecryptedMessage],
        watermarks: [UUID: MemberWatermark],
        currentUserId: UUID,
        pendingIds: Set<UUID>
    ) -> [UUID: [UUID]] {
        var heads: [UUID: [UUID]] = [:]
        // Sorted so stacked avatars keep a stable order between rebuilds.
        for (userId, mark) in watermarks.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard userId != currentUserId, let readAt = mark.readAt else { continue }
            guard let target = messages.last(where: {
                $0.type != "system" && !pendingIds.contains($0.id) && $0.createdAt <= readAt
            }) else { continue }
            heads[target.id, default: []].append(userId)
        }
        return heads
    }

    /// Status of one of my own messages against every other member's watermarks.
    static func status(
        of message: DecryptedMessage,
        watermarks: [UUID: MemberWatermark],
        currentUserId: UUID,
        pending: Bool
    ) -> Status {
        if pending { return .sending }
        let others = watermarks.filter { $0.key != currentUserId }
        let readers = others
            .filter { ($0.value.readAt ?? .distantPast) >= message.createdAt }
            .map(\.key)
            .sorted { $0.uuidString < $1.uuidString }
        if !readers.isEmpty { return .seen(readerIds: readers, everyone: readers.count == others.count) }
        if !others.isEmpty, others.values.allSatisfy({ ($0.deliveredAt ?? .distantPast) >= message.createdAt }) {
            return .delivered
        }
        return .sent
    }

    /// The label under a tapped message (or a slow send).
    static func label(_ status: Status, isGroup: Bool, nameFor: (UUID) -> String) -> String {
        switch status {
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case let .seen(readerIds, everyone):
            guard isGroup else { return "Seen" }
            if everyone { return "Seen by everyone" }
            let names = readerIds.map(nameFor)
            if names.count <= 3 { return "Seen by \(names.joined(separator: ", "))" }
            let rest = names.count - 3
            return "Seen by \(names.prefix(3).joined(separator: ", ")) and \(rest) other\(rest == 1 ? "" : "s")"
        }
    }
}
