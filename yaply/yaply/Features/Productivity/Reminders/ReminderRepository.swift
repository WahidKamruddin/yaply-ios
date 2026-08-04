import Foundation
import Supabase
import PostgREST

// Reminders schema: reminders(id, user_id, conversation_id, message, remind_at, status, created_at)
// Status: 'pending' | 'sent' | 'dismissed'
// RLS (after migration 00022): all conversation members can view/update/delete.
struct YaplyReminder: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let conversationId: UUID?
    let message: String
    var remindAt: Date
    var status: String    // "pending" | "sent" | "dismissed"
    var locked: Bool
    let createdAt: Date
    var creator: CreatorProfile?

    enum CodingKeys: String, CodingKey {
        case id, message, status, creator, locked
        case userId         = "user_id"
        case conversationId = "conversation_id"
        case remindAt       = "remind_at"
        case createdAt      = "created_at"
    }
}

final class ReminderRepository {
    // Cross-conversation feed for the Home dashboard — intentionally
    // unfiltered by conversation_id; RLS ("members can view") already scopes
    // rows to conversations the caller belongs to, mirroring
    // useDashboardReminders on web.
    func fetchAllPending(limit: Int = 20) async throws -> [YaplyReminder] {
        return try await supabase
            .from("reminders")
            .select("*, creator:profiles!reminders_user_id_fkey(display_name, username)")
            .eq("status", value: "pending")
            .order("remind_at", ascending: true)
            .limit(limit)
            .execute()
            .value
    }

    func fetchReminders(conversationId: UUID) async throws -> [YaplyReminder] {
        return try await supabase
            .from("reminders")
            .select("*, creator:profiles!reminders_user_id_fkey(display_name, username)")
            .eq("conversation_id", value: conversationId.uuidString)
            .neq("status", value: "dismissed")
            .order("remind_at", ascending: true)
            .execute()
            .value
    }

    func createReminder(conversationId: UUID, userId: UUID, message: String, remindAt: Date) async throws {
        struct Insert: Encodable {
            let conversation_id: String
            let user_id: String
            let message: String
            let remind_at: String
        }
        try await supabase
            .from("reminders")
            .insert(Insert(
                conversation_id: conversationId.uuidString,
                user_id: userId.uuidString,
                message: message,
                remind_at: remindAt.iso8601
            ))
            .execute()
    }

    func dismissReminder(id: UUID) async throws {
        struct Update: Encodable { let status: String }
        try await supabase
            .from("reminders")
            .update(Update(status: "dismissed"))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func deleteReminder(id: UUID) async throws {
        try await supabase
            .from("reminders")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    func setLocked(id: UUID, locked: Bool) async throws {
        struct Update: Encodable { let locked: Bool }
        try await supabase
            .from("reminders")
            .update(Update(locked: locked))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func updateRemindAt(reminderId: UUID, remindAt: Date) async throws {
        struct Update: Encodable { let remind_at: String }
        try await supabase
            .from("reminders")
            .update(Update(remind_at: remindAt.iso8601))
            .eq("id", value: reminderId.uuidString)
            .execute()
    }
}
