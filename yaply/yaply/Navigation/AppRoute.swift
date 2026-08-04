import Foundation

enum AppRoute: Hashable {
    case conversation(id: UUID)
    case newConversation
    case taskList(conversationId: UUID)
    case noteList(conversationId: UUID)
    case settings
    case settingsDetail(SettingsTab)
}
