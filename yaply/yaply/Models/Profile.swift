import Foundation

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var username: String
    var displayName: String?
    var avatarUrl: String?
    var bio: String?
    var publicKey: String?
    var isOnline: Bool
    var lastSeenAt: Date?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, username, bio
        case displayName  = "display_name"
        case avatarUrl    = "avatar_url"
        case publicKey    = "public_key"
        case isOnline     = "is_online"
        case lastSeenAt   = "last_seen_at"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }

    // Display name with username fallback
    var name: String { displayName ?? username }

    var initials: String {
        let n = name
        return String(n.prefix(1)).uppercased()
    }
}
