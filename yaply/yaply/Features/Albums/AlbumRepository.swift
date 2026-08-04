import Foundation
import Supabase
import PostgREST

struct YaplyAlbum: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    var name: String
    let createdBy: UUID
    let createdAt: Date
    var locked: Bool
    var creator: CreatorProfile?
    var eventId: UUID?
    var albumMedia: [AlbumMediaThumb]?

    struct AlbumMediaThumb: Codable {
        let mediaUrl: String
        enum CodingKeys: String, CodingKey { case mediaUrl = "media_url" }
    }

    var coverUrl: String? { albumMedia?.first?.mediaUrl }

    enum CodingKeys: String, CodingKey {
        case id, name, creator, locked
        case conversationId = "conversation_id"
        case createdBy      = "created_by"
        case createdAt      = "created_at"
        case eventId        = "event_id"
        case albumMedia     = "album_media"
    }
}

struct YaplyAlbumMedia: Codable, Identifiable {
    let id: UUID
    let albumId: UUID
    let messageId: UUID
    let mediaUrl: String
    let mediaMime: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case albumId   = "album_id"
        case messageId = "message_id"
        case mediaUrl  = "media_url"
        case mediaMime = "media_mime"
        case createdAt = "created_at"
    }
}

final class AlbumRepository {
    func fetchAlbums(conversationId: UUID) async throws -> [YaplyAlbum] {
        return try await supabase
            .from("albums")
            .select("*, creator:profiles!albums_created_by_fkey(display_name, username), album_media(media_url)")
            .eq("conversation_id", value: conversationId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func createAlbum(conversationId: UUID, createdBy: UUID, name: String, eventId: UUID? = nil) async throws -> YaplyAlbum {
        struct Insert: Encodable {
            let conversation_id: String
            let created_by: String
            let name: String
            let event_id: String?
        }
        return try await supabase
            .from("albums")
            .insert(Insert(conversation_id: conversationId.uuidString, created_by: createdBy.uuidString, name: name, event_id: eventId?.uuidString))
            .select()
            .single()
            .execute()
            .value
    }

    func deleteAlbum(id: UUID) async throws {
        try await supabase
            .from("albums")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    func linkToEvent(albumId: UUID, eventId: UUID) async throws {
        struct Update: Encodable { let event_id: String }
        try await supabase
            .from("albums")
            .update(Update(event_id: eventId.uuidString))
            .eq("id", value: albumId.uuidString)
            .execute()
    }

    func unlinkFromEvent(albumId: UUID) async throws {
        struct Update: Encodable { let event_id: String? }
        try await supabase
            .from("albums")
            .update(Update(event_id: nil))
            .eq("id", value: albumId.uuidString)
            .execute()
    }

    func fetchMedia(albumId: UUID) async throws -> [YaplyAlbumMedia] {
        return try await supabase
            .from("album_media")
            .select()
            .eq("album_id", value: albumId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    func addMedia(albumId: UUID, messageId: UUID, mediaUrl: String, mediaMime: String) async throws {
        struct Insert: Encodable {
            let album_id: String
            let message_id: String
            let media_url: String
            let media_mime: String
        }
        try await supabase
            .from("album_media")
            .insert(Insert(album_id: albumId.uuidString, message_id: messageId.uuidString, media_url: mediaUrl, media_mime: mediaMime))
            .execute()
    }

    func setLocked(id: UUID, locked: Bool) async throws {
        struct Update: Encodable { let locked: Bool }
        try await supabase
            .from("albums")
            .update(Update(locked: locked))
            .eq("id", value: id.uuidString)
            .execute()
    }
}
