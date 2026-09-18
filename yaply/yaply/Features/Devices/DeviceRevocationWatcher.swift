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
    private var reconnectToken: UUID?

    func start(userId: UUID) {
        stop()
        self.userId = userId
        // A socket reconnect leaves this channel joined in name only (the SDK's rejoin
        // is a no-op for subscribed channels), so it rebuilds with everything else.
        reconnectToken = RealtimeConnectionMonitor.shared.register(label: "device-revocation") { [weak self] in
            self?.start(userId: userId)
        }
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

            // Fixed topic, so created through the monitor: a stop()/start() pair (e.g. the
            // root view re-appearing) would otherwise collide with the instance still
            // being removed and never finish subscribing.
            let ch = await RealtimeConnectionMonitor.channel("device-revocation:\(rowId.uuidString)")
            guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(ch); return }
            let deletes = ch.postgresChange(
                DeleteAction.self,
                schema: "public",
                table: "devices",
                filter: .eq("id", value: rowId.uuidString)
            )
            let label = "device-revocation:\(rowId.uuidString)"
            // Non-critical: it has no reconnect closure a sweep could run, and the
            // foreground recheck() backs it up anyway.
            await RealtimeConnectionMonitor.subscribe(ch, label: label, critical: false)
            guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(ch); return }
            self.channel = ch

            self.foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.recheck() }
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await RealtimeConnectionMonitor.watch(ch, label: label) { [weak self] in
                        self?.start(userId: userId)
                    }
                }
                group.addTask {
                    for await _ in deletes {
                        await self.revokeLocally()
                        break
                    }
                }
                // Either finishing ends the watcher's current run.
                await group.next()
                group.cancelAll()
            }
        }
    }

    func stop() {
        RealtimeConnectionMonitor.shared.unregister(reconnectToken)
        reconnectToken = nil
        task?.cancel()
        task = nil
        RealtimeConnectionMonitor.remove(channel)
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
