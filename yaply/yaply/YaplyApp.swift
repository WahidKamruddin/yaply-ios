import SwiftUI
import Auth
import Supabase
import UIKit
import Kingfisher

@main
struct YaplyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var authService = AuthService()
    @State private var router = AppRouter()
    @State private var presence = PresenceService()
    @State private var notifications = NotificationManager()
    @State private var pushService = PushNotificationService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.configureImageCache()
    }

    /// Kingfisher shipped on stock defaults, which means a memory cache allowed
    /// to grow to 25% of physical RAM. Combined with full-resolution decodes
    /// that was enough to push the app into memory warnings while scrolling a
    /// photo-heavy conversation -- and an eviction there costs a re-download and
    /// a re-decode, which is exactly the scroll hitch we were chasing. Explicit,
    /// modest limits keep the cache useful without letting it become the problem.
    private static func configureImageCache() {
        let cache = ImageCache.default

        // Chat images are downsampled to bubble size before they are cached, so
        // 96MB holds a lot of them. Cap against physical RAM too, for older
        // devices where a fixed number would be a large share of the total.
        let physical = ProcessInfo.processInfo.physicalMemory
        let ceiling = UInt64(Double(physical) * 0.12)
        cache.memoryStorage.config.totalCostLimit = Int(min(UInt64(96 * 1024 * 1024), ceiling))
        cache.memoryStorage.config.expiration = .seconds(600)

        // Avatars and chat media change rarely and re-downloading them is the
        // expensive case, so the disk cache is the one worth keeping generous.
        cache.diskStorage.config.sizeLimit = 400 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(14)

        KingfisherManager.shared.downloader.downloadTimeout = 20
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authService)
                .environment(router)
                .environment(notifications)
                .environment(pushService)
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
                    // Permission can only be changed in the Settings app, so the
                    // status is re-read on return rather than cached from launch —
                    // that is what makes the disabled banner disappear without a
                    // relaunch.
                    await pushService.refreshAuthorizationStatus()
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
        // no in-app equivalent, so it gets a full banner.
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
