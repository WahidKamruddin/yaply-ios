import SwiftUI

@Observable
final class AppRouter {
    var path = NavigationPath()
    var activeConversationId: UUID?

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
