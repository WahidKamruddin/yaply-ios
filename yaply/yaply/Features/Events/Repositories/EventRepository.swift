import Foundation
import Supabase
import PostgREST

// Events schema: events(id, conversation_id, created_by, name, description, location, status, starts_at, ends_at, created_at, updated_at)
// status: 'planning' (when2meet mode) | 'confirmed' (date locked)
struct YaplyEvent: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    let createdBy: UUID
    var name: String
    var description: String?
    var location: String?
    var status: String       // "planning" | "confirmed"
    var startsAt: Date?
    var endsAt: Date?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description, location, status
        case conversationId = "conversation_id"
        case createdBy      = "created_by"
        case startsAt       = "starts_at"
        case endsAt         = "ends_at"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
    }

    var isPlanning: Bool { status == "planning" }
    var isConfirmed: Bool { status == "confirmed" }
}

final class EventRepository {
    func fetchEvents(conversationId: UUID) async throws -> [YaplyEvent] {
        return try await supabase
            .from("events")
            .select()
            .eq("conversation_id", value: conversationId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func createEvent(
        conversationId: UUID,
        createdBy: UUID,
        name: String,
        description: String? = nil,
        location: String? = nil,
        status: String = "planning",
        startsAt: Date? = nil,
        endsAt: Date? = nil
    ) async throws -> YaplyEvent {
        struct Insert: Encodable {
            let conversation_id: String
            let created_by: String
            let name: String
            let description: String?
            let location: String?
            let status: String
            let starts_at: String?
            let ends_at: String?
        }
        return try await supabase
            .from("events")
            .insert(Insert(
                conversation_id: conversationId.uuidString,
                created_by: createdBy.uuidString,
                name: name,
                description: description,
                location: location,
                status: status,
                starts_at: startsAt?.iso8601,
                ends_at: endsAt?.iso8601
            ))
            .select()
            .single()
            .execute()
            .value
    }

    func deleteEvent(id: UUID) async throws {
        try await supabase
            .from("events")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    func confirmEvent(id: UUID, startsAt: Date, endsAt: Date? = nil) async throws {
        struct Update: Encodable {
            let status: String
            let starts_at: String
            let ends_at: String?
            let updated_at: String
        }
        try await supabase
            .from("events")
            .update(Update(status: "confirmed", starts_at: startsAt.iso8601, ends_at: endsAt?.iso8601, updated_at: Date().iso8601))
            .eq("id", value: id.uuidString)
            .execute()
    }
}
