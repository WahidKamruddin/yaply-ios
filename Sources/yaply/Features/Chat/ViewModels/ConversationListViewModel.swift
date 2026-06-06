import Supabase
import Foundation

@Observable
final class ConversationListViewModel {
    private(set) var conversations: [ConversationListItem] = []
    private(set) var isLoading = false
    var error: String?

    private let repository = ConversationRepository()
    private var realtimeTask: Task<Void, Never>?

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

    // Realtime: watch for new messages and member changes to refresh the list
    private func startRealtime(userId: UUID) {
        realtimeTask?.cancel()
        realtimeTask = Task {
            let channel = supabase.channel("conversation-list-\(userId.uuidString)")
            let messageInserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "messages"
            )
            await channel.subscribe()
            for await _ in messageInserts {
                await refresh(userId: userId)
            }
        }
    }

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }
}
