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
    // unread_count (migration 00044) — the same conversations the server would
    // have counted, so a locally cleared badge and the next push agree instead of
    // overwriting each other with different numbers.
    var totalUnreadCount: Int {
        conversations
            .filter { !$0.isMessageRequest && !$0.isDeclined && !$0.isMuted }
            .reduce(0) { $0 + $1.unreadCount }
    }

    // Pending incoming friend-request count for the header badge.
    private(set) var pendingFriendRequestCount = 0

    private var _activeId: UUID?
    private let repository = ConversationRepository()
    private let friendsRepository = FriendsRepository()
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?
    private var reconnectToken: UUID?

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
        } catch {
            self.error = error.localizedDescription
        }
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

        realtimeTask = Task {
            let channel = await RealtimeConnectionMonitor.channel("conversation-list-\(userId.uuidString)-\(UUID().uuidString)")
            guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(channel); return }
            realtimeChannel = channel
            let messageInserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
            let profileUpdates = channel.postgresChange(UpdateAction.self, schema: "public", table: "profiles")
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
                group.addTask {
                    for await action in messageInserts {
                        await self.handleIncomingMessage(action)
                        await self.refresh(userId: userId)
                    }
                }
                group.addTask {
                    for await _ in profileUpdates {
                        await self.refresh(userId: userId)
                    }
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

        // Same suppression the server applies before sending a push, so the
        // in-app banner and the lock screen never disagree.
        guard !conv.isMuted, !conv.isMessageRequest, !conv.isDeclined else { return }

        let sender = conv.members.first { $0.userId == senderId }
        let senderName = sender?.profile.displayName ?? sender?.profile.username ?? "Someone"
        let convName = conv.displayName(currentUserId: currentUserId ?? UUID())

        onBackgroundMessage?(convId, convName, senderName)
    }

    func stopRealtime() {
        RealtimeConnectionMonitor.shared.unregister(reconnectToken)
        reconnectToken = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        RealtimeConnectionMonitor.remove(realtimeChannel)
        realtimeChannel = nil
    }
}
