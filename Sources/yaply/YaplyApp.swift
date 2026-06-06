import SwiftUI

@main
struct YaplyApp: App {
    @State private var authService = AuthService()
    @State private var router = AppRouter()
    @State private var presence = PresenceService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authService)
                .environment(router)
        }
        .onChange(of: scenePhase) { _, phase in
            guard let userId = authService.currentUser?.id else { return }
            Task {
                switch phase {
                case .active:     await presence.goOnline(userId: userId)
                case .background: await presence.goOffline(userId: userId)
                default:          break
                }
            }
        }
    }
}
