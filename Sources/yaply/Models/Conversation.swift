import Foundation

// Raw DB row — actual schema uses is_group (bool), not a type enum.
// See ../CLAUDE.md § Schema Discrepancy for why this differs from the migration files.
struct ConversationRow: Codable, Identifiable {
    let id: UUID
    var name: String?
    var isGroup: Bool
    var avatarUrl: String?
    let createdBy: UUID
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case isGroup    = "is_group"
        case avatarUrl  = "avatar_url"
        case createdBy  = "created_by"
        case updatedAt  = "updated_at"
    }
}

struct ConversationMemberRow: Codable {
    let conversationId: UUID
    let userId: UUID
    var isAdmin: Bool
    var isMuted: Bool
    var mutedUntil: Date?
    var lastReadAt: Date?
    var profile: Profile?

    enum CodingKeys: String, CodingKey {
        case isAdmin    = "is_admin"
        case isMuted    = "is_muted"
        case mutedUntil = "muted_until"
        case lastReadAt = "last_read_at"
        case conversationId = "conversation_id"
        case userId     = "user_id"
        case profile    = "profiles"
    }
}

// Enriched view-layer model used in the conversation list
struct ConversationListItem: Identifiable, Hashable {
    let id: UUID
    var name: String?
    var isGroup: Bool
    var avatarUrl: String?
    var members: [MemberSummary]
    var lastMessage: DecryptedMessage?
    var unreadCount: Int
    var isMuted: Bool
    var mutedUntil: Date?
    var updatedAt: Date

    // Display name: group name, or the other participant's name for direct chats
    func displayName(currentUserId: UUID) -> String {
        if isGroup { return name ?? "Group" }
        return members
            .first(where: { $0.userId != currentUserId })
            .map { $0.profile.name }
            ?? "Unknown"
    }

    func otherMember(currentUserId: UUID) -> MemberSummary? {
        members.first(where: { $0.userId != currentUserId })
    }
}

struct MemberSummary: Identifiable, Hashable {
    var id: UUID { userId }
    let userId: UUID
    let profile: Profile
    var isAdmin: Bool
    var isMuted: Bool
    var lastReadAt: Date?
}
