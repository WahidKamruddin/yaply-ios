import Supabase
import Foundation
import UserNotifications

@Observable
final class ConversationListViewModel {
    private(set) var conversations: [ConversationListItem] = []
    private(set) var isLoading = false
    var error: String?

    // Set by the view so realtime handler can filter own messages and inactive convos
    var currentUserId: UUID?
    var activeConversationId: UUID? { get { _activeId } set { _activeId = newValue } }
    var onBackgroundMessage: ((_ conversationId: UUID, _ conversationName: String, _ senderName: String) -> Void)?

    // DMs from a non-friend land 'pending' (see Friends System docs) — shown in
    // their own section, excluded (along with 'declined') from the main list.
    var messageRequests: [ConversationListItem] { conversations.filter(\.isMessageRequest) }
    var acceptedConversations: [ConversationListItem] { conversations.filter { !$0.isMessageRequest && !$0.isDeclined } }

    // What the app icon badge should read. Mirrors push_targets_for_message's
    // unread_count (migration 00045) — the same conversations the server would
    // have counted, so a locally cleared badge and the next push agree instead of
    // overwriting each other with different numbers. A muted conversation now
    // contributes only its unread @mentions (0 if "mute everything" is also on),
    // matching the server's per-message mute predicate rather than dropping the
    // whole conversation.
    var totalUnreadCount: Int {
        conversations
            .filter { !$0.isMessageRequest && !$0.isDeclined }
            .reduce(0) { $0 + ($1.isMuted ? ($1.muteMentions ? 0 : $1.mentionUnreadCount) : $1.unreadCount) }
    }

    // Pending incoming friend-request count for the header badge.
    private(set) var pendingFriendRequestCount = 0

    private var _activeId: UUID?
    private let repository = ConversationRepository()
    private let friendsRepository = FriendsRepository()
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?
    private var reconnectToken: UUID?
    private var refreshDebounce: Task<Void, Never>?
    private var deliveredDebounce: Task<Void, Never>?
    /// The delivery watermark last sent, so a refresh with nothing newer is free.
    private var deliveredUpTo: Date?

    /// What the live channel's filters were built from. When a refresh changes
    /// it (joined or left a conversation, a member changed) the channel is rebuilt.
    private struct RealtimeScope: Equatable {
        let conversationIds: Set<UUID>
        let memberIds: Set<UUID>
    }
    private var subscribedScope: RealtimeScope?
    /// Supabase Realtime's cap on an `in.(…)` filter. Past it we fall back to
    /// an unfiltered binding rather than miss events.
    private static let maxFilterValues = 100

    func load(userId: UUID) async {
        isLoading = true
        await refresh(userId: userId)
        await refreshFriendRequestCount(userId: userId)
        isLoading = false
        startRealtime(userId: userId)
    }

    func refresh(userId: UUID) async {
        do {
            conversations = try await repository.fetchConversations(userId: userId)
            await syncBadge()
            scheduleMarkDelivered()
            // The channel only hears the conversations and members it was built
            // with, so a changed set means rebuilding it (and catching up after).
            if realtimeTask != nil, let subscribedScope, currentScope() != subscribedScope {
                startRealtime(userId: userId, refetchOnSubscribe: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Delivery watermark: this device now holds everything up to the newest
    /// message it just fetched. Every realtime insert refreshes the list, so this
    /// also covers live arrivals. Debounced; skipped when nothing is newer.
    private func scheduleMarkDelivered() {
        guard let newest = conversations.compactMap({ $0.lastMessage?.createdAt }).max(),
              deliveredUpTo.map({ newest > $0 }) ?? true
        else { return }
        deliveredDebounce?.cancel()
        deliveredDebounce = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await repository.markDelivered(until: newest)
                deliveredUpTo = newest
            } catch {
                print("[yaply] failed to mark delivered: \(error)")
            }
        }
    }

    /// Coalesces a burst of realtime events into one refetch.
    private func scheduleRefresh(userId: UUID) {
        refreshDebounce?.cancel()
        refreshDebounce = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh(userId: userId)
        }
    }

    private func currentScope() -> RealtimeScope {
        var members = Set(conversations.flatMap { $0.members.map(\.userId) })
        if let currentUserId { members.remove(currentUserId) }
        return RealtimeScope(conversationIds: Set(conversations.map(\.id)), memberIds: members)
    }

    /// `in.(…)` over `values`, nil (unfiltered) past the server's cap.
    private static func inFilter(_ column: String, _ values: Set<UUID>) -> RealtimePostgresFilter? {
        guard values.count <= maxFilterValues else { return nil }
        return .in(column, values: Array(values))
    }

    // The server sets the badge on every push; nothing lowered it again, so it
    // only ever climbed. Re-applying it from the freshly fetched list is what
    // makes reading a conversation eventually clear it.
    func syncBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(totalUnreadCount)
    }

    func refreshFriendRequestCount(userId: UUID) async {
        if let requests = try? await friendsRepository.fetchFriendRequests(userId: userId) {
            pendingFriendRequestCount = requests.incoming.count
        }
    }

    func deleteConversation(id: UUID, userId: UUID) async {
        conversations.removeAll { $0.id == id }
        do {
            try await repository.deleteConversation(conversationId: id, userId: userId)
        } catch {
            self.error = error.localizedDescription
            await refresh(userId: userId)
        }
    }

    // Realtime: watch for new messages and profile presence changes to refresh the list
    func startRealtime(userId: UUID, refetchOnSubscribe: Bool = false) {
        realtimeTask?.cancel()
        RealtimeConnectionMonitor.remove(realtimeChannel)
        realtimeChannel = nil

        let label = "conversation-list-\(userId.uuidString)"
        if reconnectToken == nil {
            reconnectToken = RealtimeConnectionMonitor.shared.register(label: label) { [weak self] in
                self?.startRealtime(userId: userId, refetchOnSubscribe: true)
            }
        }

        // Filtered to this user's own conversations and their members. These used
        // to be unfiltered: every message insert and every presence heartbeat in
        // the whole database reached this channel, each one authorised per
        // subscriber server-side, and each triggered a full list refetch here.
        let scope = currentScope()
        subscribedScope = scope

        realtimeTask = Task {
            let channel = await RealtimeConnectionMonitor.channel("conversation-list-\(userId.uuidString)-\(UUID().uuidString)")
            guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(channel); return }
            realtimeChannel = channel
            // No conversations yet → nothing to hear; the first one arrives as a
            // membership insert, which rebuilds this channel.
            let messageInserts = scope.conversationIds.isEmpty ? nil : channel.postgresChange(
                InsertAction.self, schema: "public", table: "messages",
                filter: Self.inFilter("conversation_id", scope.conversationIds)
            )
            let profileUpdates = scope.memberIds.isEmpty ? nil : channel.postgresChange(
                UpdateAction.self, schema: "public", table: "profiles",
                filter: Self.inFilter("id", scope.memberIds)
            )
            // Joining a conversation (a new DM, a group add) changes the scope.
            let membershipInserts = channel.postgresChange(
                InsertAction.self, schema: "public", table: "conversation_members",
                filter: .eq("user_id", value: userId)
            )
            let friendshipInserts = channel.postgresChange(InsertAction.self, schema: "public", table: "friendships")
            let friendshipUpdates = channel.postgresChange(UpdateAction.self, schema: "public", table: "friendships")
            let friendshipDeletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "friendships")
            await RealtimeConnectionMonitor.subscribe(channel, label: label)

            // Catch up on everything missed while the socket was down — refresh() rather
            // than load() so the list doesn't flash its loading spinner on a reconnect.
            if refetchOnSubscribe {
                await self.refresh(userId: userId)
                await self.refreshFriendRequestCount(userId: userId)
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await RealtimeConnectionMonitor.watch(channel, label: label) { [weak self] in
                        self?.startRealtime(userId: userId, refetchOnSubscribe: true)
                    }
                }
                if let messageInserts {
                    group.addTask {
                        for await action in messageInserts {
                            await self.handleIncomingMessage(action)
                            await self.scheduleRefresh(userId: userId)
                        }
                    }
                }
                if let profileUpdates {
                    group.addTask {
                        for await action in profileUpdates {
                            await self.handleProfileUpdate(action.record, userId: userId)
                        }
                    }
                }
                group.addTask {
                    for await _ in membershipInserts { await self.scheduleRefresh(userId: userId) }
                }
                group.addTask {
                    for await _ in friendshipInserts { await self.refreshFriendRequestCount(userId: userId) }
                }
                group.addTask {
                    for await _ in friendshipUpdates { await self.refreshFriendRequestCount(userId: userId) }
                }
                group.addTask {
                    for await _ in friendshipDeletes { await self.refreshFriendRequestCount(userId: userId) }
                }
            }
        }
    }

    /// Presence changes (the 45s heartbeat) are patched in place — they used to
    /// refetch the whole list. A name/avatar/username change is rare and
    /// refetches, since those feed display names and row avatars.
    private func handleProfileUpdate(_ record: [String: AnyJSON], userId: UUID) {
        guard let id = record["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return }
        var needsRefresh = false
        for c in conversations.indices {
            for m in conversations[c].members.indices where conversations[c].members[m].userId == id {
                var profile = conversations[c].members[m].profile
                if record["display_name"]?.stringValue != profile.displayName
                    || record["avatar_url"]?.stringValue != profile.avatarUrl
                    || (record["username"]?.stringValue).map({ $0 != profile.username }) == true {
                    needsRefresh = true
                }
                if let isOnline = record["is_online"]?.boolValue { profile.isOnline = isOnline }
                if let raw = record["last_seen_at"]?.stringValue,
                   let lastSeen = ChatViewModel.parseRealtimeDate(raw) {
                    profile.lastSeenAt = lastSeen
                }
                conversations[c].members[m].profile = profile
            }
        }
        if needsRefresh { scheduleRefresh(userId: userId) }
    }

    private func handleIncomingMessage(_ action: InsertAction) async {
        guard
            let convIdStr = action.record["conversation_id"]?.stringValue,
            let convId = UUID(uuidString: convIdStr),
            let senderIdStr = action.record["sender_id"]?.stringValue,
            let senderId = UUID(uuidString: senderIdStr)
        else { return }

        // Skip own messages and messages in the active conversation
        guard senderId != currentUserId, convId != _activeId else { return }

        let conv = conversations.first { $0.id == convId }
        guard let conv else { return }

        // The full new row is present on a realtime INSERT — read mention
        // targeting straight off it rather than re-fetching.
        let mentionsEveryone = action.record["mentions_everyone"]?.boolValue ?? false
        let mentionedUserIds = (action.record["mentioned_user_ids"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
            .compactMap(UUID.init)
        let isMention = mentionsEveryone || (currentUserId.map(mentionedUserIds.contains) ?? false)

        // Same suppression the server applies before sending a push, so the
        // in-app banner and the lock screen never disagree. A mention bypasses
        // "mute chat" but never "mute everything" — and never a message
        // request/declined conversation, which stay absolute.
        guard !conv.isMessageRequest, !conv.isDeclined else { return }
        guard !conv.isMuted || (isMention && !conv.muteMentions) else { return }

        let sender = conv.members.first { $0.userId == senderId }
        let senderName = sender?.profile.displayName ?? sender?.profile.username ?? "Someone"
        let convName = conv.displayName(currentUserId: currentUserId ?? UUID())

        onBackgroundMessage?(convId, convName, senderName)
    }

    func stopRealtime() {
        deliveredDebounce?.cancel()
        refreshDebounce?.cancel()
        refreshDebounce = nil
        subscribedScope = nil
        RealtimeConnectionMonitor.shared.unregister(reconnectToken)
        reconnectToken = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        RealtimeConnectionMonitor.remove(realtimeChannel)
        realtimeChannel = nil
    }
}
