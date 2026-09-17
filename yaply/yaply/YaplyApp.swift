import SwiftUI
import Auth
import Supabase
import UIKit

@main
struct YaplyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var authService = AuthService()
    @State private var router = AppRouter()
    @State private var presence = PresenceService()
    @State private var notifications = NotificationManager()
    @State private var pushService = PushNotificationService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authService)
                .environment(router)
                .environment(notifications)
                .task {
                    appDelegate.pushService = pushService
                    appDelegate.router = router
                }
                .onOpenURL { url in supabase.auth.handle(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let userId = authService.currentUser?.id else { return }
            Task {
                switch phase {
                case .active:
                    await presence.goOnline(userId: userId)
                    presence.startHeartbeat(userId: userId)
                case .background:
                    presence.stopHeartbeat()
                    await presence.goOffline(userId: userId)
                default:
                    break
                }
            }
        }
        // Trigger when user signs in (covers cold launch where scenePhase fires before auth)
        .onChange(of: authService.currentUser?.id) { _, userId in
            guard let userId else {
                // The server-side row is deleted inside AuthService.signOut(),
                // which still has a session and the device id; this only drops
                // the in-memory state so the next sign-in re-uploads cleanly.
                pushService.clearLocalToken()
                return
            }
            Task {
                await presence.goOnline(userId: userId)
                presence.startHeartbeat(userId: userId)
                await pushService.requestAndRegister()
                await pushService.uploadTokenIfNeeded(userId: userId)
            }
        }
    }
}

// MARK: - AppDelegate for APNs token callbacks and notification handling

final class AppDelegate: NSObject, UIApplicationDelegate {
    var pushService: PushNotificationService?
    var router: AppRouter?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be assigned at launch. Set any later and iOS drops the
        // notification that launched the app, so a cold-launch tap goes nowhere.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            pushService?.setToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] APNs registration failed: \(error)")
    }
}

// MARK: - Foreground presentation and tap routing

extension AppDelegate: UNUserNotificationCenterDelegate {

    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let conversationId = (info["conversation_id"] as? String).flatMap(UUID.init(uuidString:))

        // Already reading this conversation — the message is on screen.
        if let conversationId, conversationId == router?.activeConversationId {
            return []
        }

        // A message push in the foreground would double up with the in-app
        // banner that ConversationListView's realtime subscription already
        // shows, so let that one win and keep only the sound and badge.
        if info["kind"] as? String == "message" {
            return [.sound, .badge]
        }

        // Everything else — friend requests, reminders, task assignments — has
        // no in-app equivalent. This is also what makes locally scheduled
        // /remind notifications present at all while the app is open.
        return [.banner, .sound, .badge]
    }

    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard
            let raw = info["conversation_id"] as? String,
            let conversationId = UUID(uuidString: raw)
        else { return }

        // Buffered rather than pushed: on a cold launch this runs before the
        // navigation stack or the session exists.
        router?.pendingConversationId = conversationId
    }
}
