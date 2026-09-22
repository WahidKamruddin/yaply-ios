import Foundation

// Raw DB row — actual schema uses type ('direct'/'group'/'ai'), not is_group bool.
struct ConversationRow: Codable, Identifiable {
    let id: UUID
    var name: String?
    var type: String
    var avatarUrl: String?
    let createdBy: UUID
    var updatedAt: Date

    var isGroup: Bool { type == "group" }

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case avatarUrl = "avatar_url"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
    }
}

struct ConversationMemberRow: Codable {
    let conversationId: UUID
    let userId: UUID
    var isAdmin: Bool
    var isMuted: Bool
    var mutedUntil: Date?
    // "Mute everything" — when true, muting this conversation also silences
    // @mentions. Meaningful only while isMuted is true.
    var muteMentions: Bool = false
    var lastReadAt: Date?
    var profile: Profile?

    enum CodingKeys: String, CodingKey {
        case isAdmin    = "is_admin"
        case isMuted    = "is_muted"
        case mutedUntil = "muted_until"
        case muteMentions = "mute_mentions"
        case lastReadAt = "last_read_at"
        case conversationId = "conversation_id"
        case userId     = "user_id"
        case profile    = "profiles"
    }

    // Decoded defensively: a select that doesn't list mute_mentions (or a row
    // fetched before that column existed) must not throw.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(UUID.self, forKey: .conversationId)
        userId = try c.decode(UUID.self, forKey: .userId)
        isAdmin = try c.decode(Bool.self, forKey: .isAdmin)
        isMuted = try c.decode(Bool.self, forKey: .isMuted)
        mutedUntil = try c.decodeIfPresent(Date.self, forKey: .mutedUntil)
        muteMentions = (try c.decodeIfPresent(Bool.self, forKey: .muteMentions)) ?? false
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile)
    }

    init(conversationId: UUID, userId: UUID, isAdmin: Bool, isMuted: Bool, mutedUntil: Date? = nil, muteMentions: Bool = false, lastReadAt: Date? = nil, profile: Profile? = nil) {
        self.conversationId = conversationId
        self.userId = userId
        self.isAdmin = isAdmin
        self.isMuted = isMuted
        self.mutedUntil = mutedUntil
        self.muteMentions = muteMentions
        self.lastReadAt = lastReadAt
        self.profile = profile
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
    // My own conversation_members.request_state — 'accepted' | 'pending' | 'declined'.
    // See the Friends System docs: a DM from a non-friend arrives 'pending' (readable,
    // not repliable until accepted); 'declined' hides the conversation entirely.
    var requestState: String
    // Unread messages that @mention me (directly or via @everyone), counted
    // separately from unreadCount so a muted group can still surface mentions.
    var mentionUnreadCount: Int = 0
    // "Mute everything" — when true, muting this conversation also silences
    // @mentions. Meaningful only while isMuted is true.
    var muteMentions: Bool = false

    var isMessageRequest: Bool { requestState == "pending" }
    var isDeclined: Bool { requestState == "declined" }

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
    var profile: Profile
    var isAdmin: Bool
    var isMuted: Bool
    var lastReadAt: Date?
}
