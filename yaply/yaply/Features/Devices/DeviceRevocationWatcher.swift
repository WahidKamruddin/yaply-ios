import Foundation
import Supabase
import Realtime
import UIKit

// Signs this install out the moment it is revoked from another device.
//
// The revoke_device RPC already deletes the auth session, so the device would
// eventually be locked out on its own — but only once its current access token
// expires, which can be an hour. That is far too long a window for "sign this
// device out", so this watcher reacts to the row disappearing and tears down
// immediately. It also re-checks when the app returns to the foreground, for
// the case where it was suspended through the realtime event.
//
// Clearing the local keys is not optional: without it the next launch would
// re-publish the same identity keypair from the Keychain and quietly undo the
// revocation. Wiping them is also what forces a re-pair to see history again.
@MainActor
@Observable
final class DeviceRevocationWatcher {
    private var channel: RealtimeChannelV2?
    private var task: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var rowId: UUID?
    private var userId: UUID?

    func start(userId: UUID) {
        stop()
        self.userId = userId
        task = Task { [weak self] in
            guard
                let self,
                let deviceId = ((try? KeyStore.loadDeviceId(forUser: userId)) ?? nil)
            else { return }

            // Resolve our own row id so the subscription can be filtered to it.
            // A delete event only carries the primary key, and filtering
            // server-side means no other user's device ids are ever observable.
            guard let rowId = await self.resolveRowId(userId: userId, deviceId: deviceId) else {
                // Successful-but-empty is handled inside resolveRowId; nil here
                // means either "revoked" (already handled) or a failed lookup,
                // which must NOT be treated as a revocation.
                return
            }
            self.rowId = rowId

            let ch = supabase.channel("device-revocation:\(rowId.uuidString)")
            let deletes = ch.postgresChange(
                DeleteAction.self,
                schema: "public",
                table: "devices",
                filter: .eq("id", value: rowId.uuidString)
            )
            try? await ch.subscribeWithError()
            self.channel = ch

            self.foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.recheck() }
            }

            for await _ in deletes {
                await self.revokeLocally()
                break
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let ch = channel { Task { await supabase.removeChannel(ch) } }
        channel = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        rowId = nil
        userId = nil
    }

    // Returns the row id, or nil. Signs out only on a SUCCESSFUL empty result —
    // a thrown error means we couldn't tell, so nothing happens.
    private func resolveRowId(userId: UUID, deviceId: Int) async -> UUID? {
        struct IdRow: Decodable { let id: UUID }
        do {
            let rows: [IdRow] = try await supabase
                .from("devices")
                .select("id")
                .eq("user_id", value: userId.uuidString)
                .eq("device_id", value: String(deviceId))
                .execute()
                .value
            if rows.isEmpty {
                await revokeLocally()
                return nil
            }
            return rows.first?.id
        } catch {
            return nil
        }
    }

    private func recheck() async {
        guard let rowId else { return }
        struct IdRow: Decodable { let id: UUID }
        do {
            let rows: [IdRow] = try await supabase
                .from("devices")
                .select("id")
                .eq("id", value: rowId.uuidString)
                .execute()
                .value
            if rows.isEmpty { await revokeLocally() }
        } catch {
            // Couldn't tell — leave the session alone.
        }
    }

    private func revokeLocally() async {
        print("[DeviceRevocationWatcher] this device was revoked — clearing keys and signing out")
        KeyStore.clearAllKeys()
        try? await supabase.auth.signOut()
        stop()
    }
}
