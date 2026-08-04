import Foundation

struct DbMessage: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID?
    var content: String
    var iv: String?
    // enc_v == 2 means envelope-encrypted (fetch this device's `message_envelopes`
    // row to unwrap); nil means phase-1 plain base64. Branch on this BEFORE iv.
    var encV: Int?
    var type: String
    var mediaUrl: String?
    var mediaMime: String?
    var replyToId: UUID?
    var threadId: UUID?
    var editedAt: Date?
    var deletedAt: Date?
    let createdAt: Date
    var senderProfile: Profile?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId  = "conversation_id"
        case senderId        = "sender_id"
        case content, iv
        case encV            = "enc_v"
        case type
        case mediaUrl        = "media_url"
        case mediaMime       = "media_mime"
        case replyToId       = "reply_to_id"
        case threadId        = "thread_id"
        case editedAt        = "edited_at"
        case deletedAt       = "deleted_at"
        case createdAt       = "created_at"
        case senderProfile   = "profiles"
    }

    var isDeleted: Bool { deletedAt != nil }
}

struct DecryptedMessage: Identifiable, Hashable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID?
    var content: String
    var type: String
    var mediaUrl: String?
    var replyToId: UUID?
    var threadId: UUID?
    var editedAt: Date?
    var deletedAt: Date?
    var createdAt: Date
    var senderProfile: Profile?
    // True when this is an enc_v=2 message with no envelope for this device (sealed
    // before this device existed) or any other decrypt failure — an honest, permanent
    // state. `content` is left empty; never render raw ciphertext or garbled bytes.
    var decryptFailed: Bool = false

    var isDeleted: Bool { deletedAt != nil }
    var isText: Bool { type == "text" }
    var isMedia: Bool { ["image", "gif", "sticker"].contains(type) }
}

struct SendMessageParams: Encodable {
    let conversationId: UUID
    let senderId: UUID
    let content: String
    let iv: String?
    let type: String
    let mediaUrl: String?
    let mediaMime: String?
    let replyToId: UUID?
    let threadId: UUID?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case senderId       = "sender_id"
        case content, iv, type
        case mediaUrl       = "media_url"
        case mediaMime      = "media_mime"
        case replyToId      = "reply_to_id"
        case threadId       = "thread_id"
    }

    init(
        conversationId: UUID,
        senderId: UUID,
        content: String,
        iv: String? = nil,
        type: String = "text",
        mediaUrl: String? = nil,
        mediaMime: String? = nil,
        replyToId: UUID? = nil,
        threadId: UUID? = nil
    ) {
        self.conversationId = conversationId
        self.senderId = senderId
        self.content = content
        self.iv = iv
        self.type = type
        self.mediaUrl = mediaUrl
        self.mediaMime = mediaMime
        self.replyToId = replyToId
        self.threadId = threadId
    }
}

// MARK: - Reactions

struct Reaction: Codable, Identifiable {
    let messageId: UUID
    let userId: UUID
    let emoji: String

    var id: String { "\(messageId)-\(userId)-\(emoji)" }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case userId    = "user_id"
        case emoji
    }
}

struct ReactionGroup: Identifiable, Equatable {
    let emoji: String
    var count: Int
    var reactedByMe: Bool

    var id: String { emoji }
}
