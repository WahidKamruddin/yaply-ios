import Foundation

enum AppRoute: Hashable {
    case conversation(id: UUID)
    case newConversation
    case taskList(conversationId: UUID)
    case noteList(conversationId: UUID)
    case settings
    case settingsDetail(SettingsTab)
    case friends
    case messageRequests

    /// The shared productivity panel for a conversation (Tasks / Notes /
    /// Reminders / Events / Albums / Budgets), pushed as a page rather than
    /// presented as a sheet.
    case conversationPanel(conversationId: UUID, members: [MemberSummary], tab: String)

    /// A single event / plan, pushed as its own page.
    case eventDetail(YaplyEvent)

    /// A single album's gallery, pushed as its own page.
    case albumDetail(album: YaplyAlbum, isCurrentUserAdmin: Bool)
}
