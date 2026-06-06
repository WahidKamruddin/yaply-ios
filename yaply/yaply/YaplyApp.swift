import SwiftUI
import Auth
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
                .task { appDelegate.pushService = pushService }
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
        // Trigger when user signs in (covers cold launch where scenePhase fires before auth)
        .onChange(of: authService.currentUser?.id) { _, userId in
            guard let userId else { return }
            Task {
                await presence.goOnline(userId: userId)
                await pushService.requestAndRegister()
                await pushService.uploadTokenIfNeeded(userId: userId)
            }
        }
    }
}

// MARK: - AppDelegate for APNs token callbacks

final class AppDelegate: NSObject, UIApplicationDelegate {
    var pushService: PushNotificationService?

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

    // Deep link: tapping a push notification opens the correct conversation
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(.newData)
    }
}
