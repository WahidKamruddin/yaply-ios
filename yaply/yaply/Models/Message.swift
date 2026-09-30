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
    // Group-chat-only @mention targeting — a plaintext side-channel beside
    // encrypted content, since the server can't read ciphertext to fan out
    // mention-aware push/badge notifications. See ../CLAUDE.md's mentions section.
    // Decoded defensively: an old cached row (or a row from before this column
    // existed) must not throw.
    var mentionedUserIds: [UUID] = []
    var mentionsEveryone: Bool = false

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
        case mentionedUserIds = "mentioned_user_ids"
        case mentionsEveryone = "mentions_everyone"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationId = try c.decode(UUID.self, forKey: .conversationId)
        senderId = try c.decodeIfPresent(UUID.self, forKey: .senderId)
        content = try c.decode(String.self, forKey: .content)
        iv = try c.decodeIfPresent(String.self, forKey: .iv)
        encV = try c.decodeIfPresent(Int.self, forKey: .encV)
        type = try c.decode(String.self, forKey: .type)
        mediaUrl = try c.decodeIfPresent(String.self, forKey: .mediaUrl)
        mediaMime = try c.decodeIfPresent(String.self, forKey: .mediaMime)
        replyToId = try c.decodeIfPresent(UUID.self, forKey: .replyToId)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        senderProfile = try c.decodeIfPresent(Profile.self, forKey: .senderProfile)
        mentionedUserIds = (try c.decodeIfPresent([UUID].self, forKey: .mentionedUserIds)) ?? []
        mentionsEveryone = (try c.decodeIfPresent(Bool.self, forKey: .mentionsEveryone)) ?? false
    }

    init(
        id: UUID, conversationId: UUID, senderId: UUID?, content: String, iv: String? = nil,
        encV: Int? = nil, type: String, mediaUrl: String? = nil, mediaMime: String? = nil,
        replyToId: UUID? = nil, threadId: UUID? = nil, editedAt: Date? = nil, deletedAt: Date? = nil,
        createdAt: Date, senderProfile: Profile? = nil,
        mentionedUserIds: [UUID] = [], mentionsEveryone: Bool = false
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.content = content
        self.iv = iv
        self.encV = encV
        self.type = type
        self.mediaUrl = mediaUrl
        self.mediaMime = mediaMime
        self.replyToId = replyToId
        self.threadId = threadId
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.senderProfile = senderProfile
        self.mentionedUserIds = mentionedUserIds
        self.mentionsEveryone = mentionsEveryone
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
    // Present when the sender attached a resolved link preview (type="text"
    // only). Decoded out of `content` by LinkPreviewCodec at every decrypt
    // site — see ../CLAUDE.md's "Link previews" section.
    var linkPreview: LinkPreview?
    // The optimistic temp id this message was sent under, kept after the
    // server confirms it. Rows are keyed by `rowId`, so the temp → real swap
    // keeps the same SwiftUI identity instead of removing and re-inserting
    // the row (which would cut the send flight short and replay transitions).
    var localId: UUID? = nil

    var isDeleted: Bool { deletedAt != nil }
    var isText: Bool { type == "text" }
    /// Stable list identity: the temp id for this device's own sends, else `id`.
    var rowId: UUID { localId ?? id }
    var isMedia: Bool { ["image", "gif", "sticker"].contains(type) }

    /// Short, human label for list/banner previews. Media types carry no text
    /// content (`content == ""` by design), so this substitutes a type-based
    /// label instead of showing a blank string.
    var previewText: String {
        // System messages carry a future deletedAt (their 7-day expiry), so
        // they're checked before the deleted state.
        if type == "system" { return SystemItem.previewText(content) }
        if isDeleted { return "Message deleted" }
        // Never ciphertext: an envelope this device can't open previews honestly.
        if decryptFailed { return "🔒 Encrypted message" }
        switch type {
        case "sticker": return "Sticker"
        case "gif": return "GIF"
        case "image": return "📷 Photo"
        case "voice": return "🎤 Voice message"
        case "file": return "📎 File"
        default:
            if content.isEmpty, let linkPreview {
                return "🔗 \(linkPreview.title ?? linkPreview.siteName ?? linkPreview.url)"
            }
            return content
        }
    }
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
    // Group-chat-only; always empty/false outside groups. See DbMessage.
    let mentionedUserIds: [UUID]
    let mentionsEveryone: Bool

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case senderId       = "sender_id"
        case content, iv, type
        case mediaUrl       = "media_url"
        case mediaMime      = "media_mime"
        case replyToId      = "reply_to_id"
        case threadId       = "thread_id"
        case mentionedUserIds = "mentioned_user_ids"
        case mentionsEveryone = "mentions_everyone"
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
        threadId: UUID? = nil,
        mentionedUserIds: [UUID] = [],
        mentionsEveryone: Bool = false
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
        self.mentionedUserIds = mentionedUserIds
        self.mentionsEveryone = mentionsEveryone
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
