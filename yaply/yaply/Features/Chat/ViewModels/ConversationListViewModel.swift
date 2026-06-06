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

    private var _activeId: UUID?
    private let repository = ConversationRepository()
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?

    func load(userId: UUID) async {
        isLoading = true
        await refresh(userId: userId)
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
