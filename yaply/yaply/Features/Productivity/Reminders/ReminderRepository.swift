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
    let remindAt: Date
    var status: String    // "pending" | "sent" | "dismissed"
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, message, status
        case userId         = "user_id"
        case conversationId = "conversation_id"
        case remindAt       = "remind_at"
        case createdAt      = "created_at"
    }
}

final class ReminderRepository {
    func fetchReminders(conversationId: UUID) async throws -> [YaplyReminder] {
        return try await supabase
            .from("reminders")
            .select()
            .eq("conversation_id", value: conversationId.uuidString)
            .neq("status", value: "dismissed")
            .order("remind_at", ascending: true)
            .execute()
            .value
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
}
