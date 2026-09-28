import Foundation

/// A run of consecutive messages that share a calendar day, i.e. everything
/// between two date separators.
struct MessageDateGroup: Identifiable {
    let date: Date
    let messages: [DecryptedMessage]
    var id: Date { date }
}

/// Everything the message list needs to know about a `[DecryptedMessage]` that
/// isn't stored on the messages themselves: the date separators, each bubble's
/// position in its sender run, and which bubbles start a new speaker.
///
/// This used to be recomputed inside `ChatView.body` -- once per date group for
/// the grouping, plus an O(n) `threadCounts` walk and an O(n) reply lookup *per
/// row*, making the list O(n^2) per evaluation. Since the body was also being
/// re-evaluated on every scroll frame, that was the bulk of the scroll cost.
/// Building it once, when `messages` actually changes, is the fix.
struct MessageListLayout {
    var groups: [MessageDateGroup] = []
    var positions: [UUID: BubblePosition] = [:]
    var newSpeakerIds: Set<UUID> = []
    /// Reply lookups were a linear scan of the whole array per row.
    var messagesById: [UUID: DecryptedMessage] = [:]
    var threadCounts: [UUID: Int] = [:]
    var lastOwnMessageId: UUID?
    /// Messenger-style "seen" avatars: message id → the members whose read
    /// watermark lands on it (see `ReadReceipts.seenHeads`).
    var seenHeads: [UUID: [UUID]] = [:]
    /// Watermarks after `ReadReceipts.withImpliedReads` — what the tapped
    /// status line must be computed against too.
    var effectiveWatermarks: [UUID: MemberWatermark] = [:]

    /// `Calendar.current` bridges a fresh value on every access, and the old
    /// code called it twice per message per frame. One shared instance is
    /// enough -- the chat does not switch calendars mid-scroll.
    private static let calendar = Calendar.current

    static func build(
        _ messages: [DecryptedMessage],
        isGroupConversation: Bool,
        currentUserId: UUID,
        watermarks: [UUID: MemberWatermark] = [:],
        pendingIds: Set<UUID> = []
    ) -> MessageListLayout {
        var layout = MessageListLayout()
        guard !messages.isEmpty else { return layout }

        layout.effectiveWatermarks = ReadReceipts.withImpliedReads(
            messages: messages, watermarks: watermarks, pendingIds: pendingIds
        )
        layout.seenHeads = ReadReceipts.seenHeads(
            messages: messages, watermarks: layout.effectiveWatermarks,
            currentUserId: currentUserId, pendingIds: pendingIds
        )

        layout.messagesById = Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        for msg in messages {
            if let tid = msg.threadId { layout.threadCounts[tid, default: 0] += 1 }
        }

        layout.lastOwnMessageId = messages
            .last(where: { $0.senderId == currentUserId && !$0.isDeleted })?.id

        // Date grouping — same walk as the old `ChatView.groupByDate`.
        var groups: [MessageDateGroup] = []
        var currentDay: Date?
        var current: [DecryptedMessage] = []
        for msg in messages {
            let day = calendar.startOfDay(for: msg.createdAt)
            if let currentDay, calendar.isDate(day, inSameDayAs: currentDay) {
                current.append(msg)
            } else {
                if let currentDay, !current.isEmpty {
                    groups.append(MessageDateGroup(date: currentDay, messages: current))
                }
                currentDay = day
                current = [msg]
            }
        }
        if let currentDay, !current.isEmpty {
            groups.append(MessageDateGroup(date: currentDay, messages: current))
        }
        layout.groups = groups

        for group in groups {
            layout.positions.merge(BubblePosition.positions(for: group.messages)) { _, new in new }
            if isGroupConversation {
                for (prev, next) in zip(group.messages, group.messages.dropFirst())
                where prev.senderId != next.senderId {
                    layout.newSpeakerIds.insert(next.id)
                }
            }
        }

        return layout
    }
}
