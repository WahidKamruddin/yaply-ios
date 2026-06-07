import Foundation
import Supabase
import PostgREST

// Notes schema: notes(id, user_id, conversation_id, title, content, created_at, updated_at)
// RLS: owner only — user can only see/modify their own notes.
struct YaplyNote: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID?
    let userId: UUID
    var title: String
    var content: String
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, content
        case conversationId = "conversation_id"
        case userId         = "user_id"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
    }
}

final class NoteRepository {
    func fetchNotes(conversationId: UUID) async throws -> [YaplyNote] {
        return try await supabase
            .from("notes")
            .select()
            .eq("conversation_id", value: conversationId.uuidString)
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    func createNote(conversationId: UUID, userId: UUID, title: String, content: String = "") async throws -> YaplyNote {
        struct Insert: Encodable {
            let conversation_id: String
            let user_id: String
            let title: String
            let content: String
        }
        return try await supabase
            .from("notes")
            .insert(Insert(conversation_id: conversationId.uuidString, user_id: userId.uuidString, title: title, content: content))
            .select()
            .single()
            .execute()
            .value
    }

    func updateNote(id: UUID, content: String) async throws {
        struct Update: Encodable {
            let content: String
            let updated_at: String
        }
        try await supabase
            .from("notes")
            .update(Update(content: content, updated_at: Date().iso8601))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func deleteNote(id: UUID) async throws {
        try await supabase
            .from("notes")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }
}
