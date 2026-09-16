import Foundation
import Supabase
import PostgREST

// Updates is_online and last_seen_at on the profiles table.
// Driven by YaplyApp via .onChange(of: scenePhase): goOnline+startHeartbeat on
// .active, stopHeartbeat+goOffline on .background.
//
// There is no Supabase Realtime presence channel here (see the CLAUDE.md known
// gap) — this is a plain table write, which can't reliably detect a crash,
// force-quit, or network loss while foregrounded. The foreground heartbeat
// re-touches last_seen_at periodically so `Profile.effectiveOnline` (which
// requires a recent last_seen_at, not just the raw is_online flag) degrades a
// stuck-online row to "offline" within one missed beat instead of staying
// wrong forever.
@MainActor
final class PresenceService {
    /// How often the heartbeat re-touches last_seen_at while foregrounded.
    static let heartbeatInterval: TimeInterval = 45
    /// A profile is only treated as online if last_seen_at is newer than this.
    /// Two missed heartbeats' worth of slack to absorb one dropped write.
    static let staleAfter: TimeInterval = 2 * heartbeatInterval

    private var heartbeatTask: Task<Void, Never>?

    func goOnline(userId: UUID) async {
        struct OnlineUpdate: Encodable {
            let is_online: Bool
            let last_seen_at: String
        }
        do {
            _ = try await supabase
                .from("profiles")
                .update(OnlineUpdate(is_online: true, last_seen_at: Date().iso8601))
                .eq("id", value: userId.uuidString)
                .execute()
        } catch {
            print("[Presence] goOnline failed for \(userId): \(error)")
        }
    }

    func goOffline(userId: UUID) async {
        struct OfflineUpdate: Encodable {
            let is_online: Bool
            let last_seen_at: String
        }
        do {
            _ = try await supabase
                .from("profiles")
                .update(OfflineUpdate(is_online: false, last_seen_at: Date().iso8601))
                .eq("id", value: userId.uuidString)
                .execute()
        } catch {
            print("[Presence] goOffline failed for \(userId): \(error)")
        }
    }

    /// Starts (or restarts) the foreground heartbeat for `userId`. Safe to call
    /// repeatedly — a prior heartbeat is cancelled first so there's only ever
    /// one loop running.
    func startHeartbeat(userId: UUID) {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.goOnline(userId: userId)
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
