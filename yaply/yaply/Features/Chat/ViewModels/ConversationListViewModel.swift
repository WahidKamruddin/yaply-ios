import Supabase
import Foundation

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

    // Pending incoming friend-request count for the header badge.
    private(set) var pendingFriendRequestCount = 0

    private var _activeId: UUID?
    private let repository = ConversationRepository()
    private let friendsRepository = FriendsRepository()
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?

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
        } catch {
            self.error = error.localizedDescription
        }
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
    private func startRealtime(userId: UUID) {
        realtimeTask?.cancel()
        if let ch = realtimeChannel {
            Task { await supabase.removeChannel(ch) }
            realtimeChannel = nil
        }
        realtimeTask = Task {
            let channel = supabase.channel("conversation-list-\(userId.uuidString)-\(UUID().uuidString)")
            realtimeChannel = channel
            let messageInserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
            let profileUpdates = channel.postgresChange(UpdateAction.self, schema: "public", table: "profiles")
            let friendshipInserts = channel.postgresChange(InsertAction.self, schema: "public", table: "friendships")
            let friendshipUpdates = channel.postgresChange(UpdateAction.self, schema: "public", table: "friendships")
            let friendshipDeletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "friendships")
            try? await channel.subscribeWithError()
            await withTaskGroup(of: Void.self) { group in
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

        let sender = conv.members.first { $0.userId == senderId }
        let senderName = sender?.profile.displayName ?? sender?.profile.username ?? "Someone"
        let convName = conv.displayName(currentUserId: currentUserId ?? UUID())

        onBackgroundMessage?(convId, convName, senderName)
    }

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        if let ch = realtimeChannel {
            Task { await supabase.removeChannel(ch) }
            realtimeChannel = nil
        }
    }
}
