import SwiftUI

@Observable
final class AppRouter {
    var path = NavigationPath()
    var activeConversationId: UUID?

    // Set when a push notification is tapped. Buffered rather than pushed
    // directly because the tap can arrive on a cold launch, before the
    // navigation stack exists or the session has loaded — ContentView drains it
    // once it is able to navigate.
    var pendingConversationId: UUID?

    func consumePendingConversation() {
        guard let conversationId = pendingConversationId else { return }
        pendingConversationId = nil
        popToRoot()
        push(.conversation(id: conversationId))
    }

    func push(_ route: AppRoute) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path.removeLast(path.count)
    }
}
