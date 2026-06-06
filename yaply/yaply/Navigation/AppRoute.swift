import Foundation

enum AppRoute: Hashable {
    case conversation(id: UUID)
    case newConversation
    case profile(userId: UUID)
    case taskList(conversationId: UUID)
    case noteList(conversationId: UUID)
    case settings
}
