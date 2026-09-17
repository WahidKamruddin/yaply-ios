import Foundation
import UserNotifications
import UIKit
import Supabase
import PostgREST

// Which APNs host the server must use for this install's token. Read from the
// provisioning profile rather than #if DEBUG: the two agree for Xcode-run and
// App Store builds, but diverge for ad-hoc and enterprise ones. Getting it
// wrong means every send returns 400 BadDeviceToken and the server prunes the
// token — the user silently stops receiving notifications with no visible error.
enum ApnsEnvironment {
    static var current: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            // The profile is a CMS blob with an XML plist embedded in it; isoLatin1
            // round-trips arbitrary bytes so the plist range can be sliced out.
            let raw = String(data: data, encoding: .isoLatin1),
            let start = raw.range(of: "<plist"),
            let end = raw.range(of: "</plist>"),
            let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let environment = entitlements["aps-environment"] as? String
        else {
            // App Store builds are the case that matters if parsing ever fails.
            return "production"
        }
        return environment == "development" ? "sandbox" : "production"
        #endif
    }
}

@Observable
@MainActor
final class PushNotificationService {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastUploadError: String?

    private var pendingToken: Data?
    // Stored so setToken can upload when the token arrives after sign-in.
    private var knownUserId: UUID?

    func requestAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            print("[Push] Permission request failed: \(error)")
        }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // Called from AppDelegate when APNs delivers a token, which happens
    // asynchronously some time after registerForRemoteNotifications.
    func setToken(_ tokenData: Data) {
        pendingToken = tokenData
        if let userId = knownUserId {
            Task { await uploadToken(tokenData, userId: userId) }
        }
    }

    // Called once the user id is known. Uploads if a token is already waiting.
    func uploadTokenIfNeeded(userId: UUID) async {
        knownUserId = userId
        guard let tokenData = pendingToken else { return }
        await uploadToken(tokenData, userId: userId)
    }

    // Removes this install's token so a signed-out device stops receiving the
    // departed account's messages.
    //
    // Must run BEFORE AuthService tears the session down: the delete is an
    // RLS-checked write that needs a live session, and it needs the device id
    // that clearAllKeys() is about to wipe. Static because sign-out is driven
    // by AuthService, which has no handle on this service.
    static func removeToken(userId: UUID) async {
        guard let deviceId = try? KeyStore.loadDeviceId(forUser: userId) else { return }
        do {
            try await supabase
                .from("push_tokens")
                .delete()
                .eq("user_id", value: userId.uuidString)
                .eq("device_id", value: deviceId)
                .execute()
        } catch {
            print("[Push] Token delete failed: \(error)")
        }
    }

    func clearLocalToken() {
        knownUserId = nil
        pendingToken = nil
    }

    private struct TokenRow: Encodable {
        let user_id: String
        let device_id: Int
        let token: String
        let platform: String
        let environment: String
    }

    private func uploadToken(_ tokenData: Data, userId: UUID) async {
        // push_tokens has a composite FK onto the devices row, so registration
        // must have completed first. EncryptionRegistrar writes that row, and
        // APNs can deliver the token before it does — retry rather than drop.
        for attempt in 0..<5 {
            guard let deviceId = try? KeyStore.loadDeviceId(forUser: userId) else {
                try? await Task.sleep(for: .seconds(1 << attempt))
                continue
            }

            let row = TokenRow(
                user_id: userId.uuidString,
                device_id: deviceId,
                token: tokenData.map { String(format: "%02x", $0) }.joined(),
                platform: "ios",
                environment: ApnsEnvironment.current
            )

            do {
                try await supabase
                    .from("push_tokens")
                    .upsert(row, onConflict: "user_id,device_id")
                    .execute()
                pendingToken = nil
                lastUploadError = nil
                return
            } catch {
                // 23503 means the devices row is not there yet — that is the
                // race above and it is worth waiting out. Anything else is a
                // real failure and retrying will not help.
                guard isForeignKeyViolation(error) else {
                    lastUploadError = "\(error)"
                    print("[Push] Token upload failed: \(error)")
                    return
                }
                try? await Task.sleep(for: .seconds(1 << attempt))
            }
        }

        lastUploadError = "Device registration did not complete; push token not uploaded."
        print("[Push] \(lastUploadError ?? "")")
    }

    private func isForeignKeyViolation(_ error: Error) -> Bool {
        if let postgrestError = error as? PostgrestError, postgrestError.code == "23503" { return true }
        return "\(error)".contains("23503")
    }
}
