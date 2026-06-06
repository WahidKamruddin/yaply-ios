import SwiftUI
import Auth

struct ContentView: View {
    @Environment(AuthService.self) private var authService
    @Environment(AppRouter.self) private var router
    @Environment(NotificationManager.self) private var notifications

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if authService.isLoading {
                    splashView
                } else if authService.currentUser == nil {
                    AuthView(authService: authService)
                } else if let userId = authService.currentUser?.id {
                    mainNavigationView(userId: userId)
                }
            }

            // In-app notification banner
            if let n = notifications.current {
                InAppBannerView(
                    notification: n,
                    onTap: {
                        notifications.dismiss()
                        router.push(.conversation(id: n.conversationId))
                    },
                    onDismiss: { notifications.dismiss() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
                .zIndex(999)
                .animation(.spring(duration: 0.35), value: notifications.current?.id)
            }
        }
        .animation(.spring(duration: 0.35), value: notifications.current?.id)
    }

    private var splashView: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Circle()
                    .fill(Color.yaplyAccent)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text("Y").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    )
                ProgressView().tint(Color.yaplyAccent)
            }
        }
    }

    private func mainNavigationView(userId: UUID) -> some View {
        @Bindable var bindableRouter = router
        return NavigationStack(path: $bindableRouter.path) {
            ConversationListView(currentUserId: userId)
                .navigationDestination(for: AppRoute.self) { route in
                    destinationView(for: route, userId: userId)
                }
        }
    }

    @ViewBuilder
    private func destinationView(for route: AppRoute, userId: UUID) -> some View {
        switch route {
        case .conversation(let convId):
            ChatView(
                conversationId: convId,
                currentUserId: userId,
                currentUsername: authService.currentUser?.userMetadata["username"]?.stringValue
                    ?? authService.currentUser?.email?.components(separatedBy: "@").first
                    ?? "Me",
                conversationName: "Chat",
                otherMember: nil
            )
        case .newConversation:
            NewConversationView(currentUserId: userId) { convId in
                router.push(.conversation(id: convId))
            }
        case .taskList(let convId):
            TaskListView(conversationId: convId, currentUserId: userId)
        case .noteList:
            Text("Notes — coming soon").foregroundStyle(Color.yaplySecondary)
        case .profile:
            Text("Profile — coming soon").foregroundStyle(Color.yaplySecondary)
        case .settings:
            SettingsView()
        }
    }
}
