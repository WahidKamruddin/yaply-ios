import Foundation
import Foundation
import Supabase
import PostgREST

// Updates is_online and last_seen_at on the profiles table.
// Called from YaplyApp via .onChange(of: scenePhase).
final class PresenceService {
    func goOnline(userId: UUID) async {
        struct OnlineUpdate: Encodable {
            let is_online: Bool
        }
        try? await supabase
            .from("profiles")
            .update(OnlineUpdate(is_online: true))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    func goOffline(userId: UUID) async {
        struct OfflineUpdate: Encodable {
            let is_online: Bool
            let last_seen_at: String
        }
        try? await supabase
            .from("profiles")
            .update(OfflineUpdate(is_online: false, last_seen_at: Date().iso8601))
            .eq("id", value: userId.uuidString)
            .execute()
    }
}
