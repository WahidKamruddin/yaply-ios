import Foundation
import UserNotifications
import UIKit
import Supabase

@Observable
@MainActor
final class PushNotificationService {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var pendingToken: Data?
    // Stored so setToken can trigger upload when token arrives after auth is already established
    private var knownUserId: UUID?

    func requestAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authorizationStatus = settings.authorizationStatus
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            print("[Push] Permission request failed: \(error)")
        }
    }

    // Called from AppDelegate when APNs delivers a token (asynchronously after registerForRemoteNotifications)
    func setToken(_ tokenData: Data) {
        pendingToken = tokenData
        // If the user is already authenticated (token arrived after sign-in), upload immediately.
        // This handles first-install where uploadTokenIfNeeded ran before the token arrived.
        if let userId = knownUserId {
            Task { await uploadToken(tokenData, userId: userId) }
        }
    }

    // Call this when the user ID becomes known. Triggers upload if a token is already pending.
    func uploadTokenIfNeeded(userId: UUID) async {
        knownUserId = userId
        guard let tokenData = pendingToken else { return }
        await uploadToken(tokenData, userId: userId)
    }

    private func uploadToken(_ tokenData: Data, userId: UUID) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        struct Sub: Encodable {
            let user_id: String
            let endpoint: String
            let p256dh: String
            let auth: String
            let platform: String
        }
        do {
            try await supabase
                .from("push_subscriptions")
                .upsert(
                    Sub(user_id: userId.uuidString, endpoint: token, p256dh: "", auth: "", platform: "ios"),
                    onConflict: "user_id,endpoint"
                )
                .execute()
            pendingToken = nil
        } catch {
            print("[Push] Token upload failed: \(error)")
        }
    }
}
