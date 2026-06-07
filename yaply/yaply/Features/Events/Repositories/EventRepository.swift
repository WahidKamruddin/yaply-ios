import Foundation
import Supabase
import PostgREST

// MARK: - Models

struct YaplyEventAvailability: Codable, Identifiable {
    let id: UUID
    let eventId: UUID
    let userId: UUID
    var slots: [String]   // ISO8601 UTC strings matching web slotKey format
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, slots
        case eventId   = "event_id"
        case userId    = "user_id"
        case updatedAt = "updated_at"
    }
}

struct AvailMember: Identifiable {
    let userId: UUID
    let username: String?
    let displayName: String?
    let avatarUrl: String?

    var id: UUID { userId }
    var name: String { displayName ?? username ?? "Member" }
    var initials: String { String((displayName ?? username ?? "?").prefix(1)).uppercased() }
}

struct YaplyEventRsvp: Codable, Identifiable {
    let id: UUID
    let eventId: UUID
    let userId: UUID
    var response: String   // "going" | "maybe" | "not_going" | "pending"
    var updatedAt: Date
    var profile: RsvpProfile?

    struct RsvpProfile: Codable {
        let id: UUID
        let username: String?
        let displayName: String?
        let avatarUrl: String?

        enum CodingKeys: String, CodingKey {
            case id, username
            case displayName = "display_name"
            case avatarUrl   = "avatar_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, response
        case eventId   = "event_id"
        case userId    = "user_id"
        case updatedAt = "updated_at"
        case profile   = "profiles"
    }
}

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
    var creator: CreatorProfile?

    enum CodingKeys: String, CodingKey {
        case id, name, description, location, status, creator
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
            .select("*, creator:profiles!events_created_by_fkey(display_name, username)")
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

    // MARK: - Availability

    func fetchAvailability(eventId: UUID) async throws -> [YaplyEventAvailability] {
        return try await supabase
            .from("event_availability")
            .select()
            .eq("event_id", value: eventId.uuidString)
            .execute()
            .value
    }

    func setAvailability(eventId: UUID, userId: UUID, slots: [String]) async throws {
        struct Upsert: Encodable {
            let event_id: String
            let user_id: String
            let slots: [String]
            let updated_at: String
        }
        try await supabase
            .from("event_availability")
            .upsert(
                Upsert(
                    event_id: eventId.uuidString,
                    user_id: userId.uuidString,
                    slots: slots,
                    updated_at: Date().iso8601
                ),
                onConflict: "event_id,user_id"
            )
            .execute()
    }

    func fetchEventMembers(conversationId: UUID) async throws -> [AvailMember] {
        struct MemberRow: Codable {
            let userId: UUID
            let profile: ProfileData?

            struct ProfileData: Codable {
                let id: UUID
                let username: String?
                let displayName: String?
                let avatarUrl: String?

                enum CodingKeys: String, CodingKey {
                    case id, username
                    case displayName = "display_name"
                    case avatarUrl   = "avatar_url"
                }
            }

            enum CodingKeys: String, CodingKey {
                case userId  = "user_id"
                case profile = "profiles"
            }
        }

        let rows: [MemberRow] = try await supabase
            .from("conversation_members")
            .select("user_id, profiles(id, username, display_name, avatar_url)")
            .eq("conversation_id", value: conversationId.uuidString)
            .execute()
            .value

        return rows.compactMap { row in
            guard let p = row.profile else { return nil }
            return AvailMember(userId: row.userId, username: p.username, displayName: p.displayName, avatarUrl: p.avatarUrl)
        }
    }

    // MARK: - RSVP

    func fetchRsvps(eventId: UUID) async throws -> [YaplyEventRsvp] {
        return try await supabase
            .from("event_rsvp")
            .select("*, profiles!user_id(id, username, display_name, avatar_url)")
            .eq("event_id", value: eventId.uuidString)
            .execute()
            .value
    }

    func setRsvp(eventId: UUID, userId: UUID, response: String) async throws {
        struct Upsert: Encodable {
            let event_id: String
            let user_id: String
            let response: String
            let updated_at: String
        }
        try await supabase
            .from("event_rsvp")
            .upsert(
                Upsert(
                    event_id: eventId.uuidString,
                    user_id: userId.uuidString,
                    response: response,
                    updated_at: Date().iso8601
                ),
                onConflict: "event_id,user_id"
            )
            .execute()
    }

    // MARK: - Linked Resources

    func fetchLinkedAlbums(eventId: UUID) async throws -> [YaplyAlbum] {
        return try await supabase
            .from("albums")
            .select("*, creator:profiles!albums_created_by_fkey(display_name, username), album_media(media_url)")
            .eq("event_id", value: eventId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchLinkedBudgets(eventId: UUID) async throws -> [YaplyBudget] {
        return try await supabase
            .from("budgets")
            .select("*, creator:profiles!budgets_created_by_fkey(display_name, username)")
            .eq("event_id", value: eventId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }
}
