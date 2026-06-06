import Foundation

// Raw DB row — actual column names differ from the migration files.
// message_type is an integer; 3 = text. server_timestamp is the sort column.
struct DbMessage: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID?
    var encryptedContent: String
    var messageType: Int
    var senderDeviceId: Int?
    var contentHint: String?
    var encryptedAttachmentRef: String?
    var parentMessageId: UUID?
    var threadName: String?
    var deletedAt: Date?
    var serverTimestamp: Date
    let createdAt: Date
    var senderProfile: Profile?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId          = "conversation_id"
        case senderId                = "sender_id"
        case encryptedContent        = "encrypted_content"
        case messageType             = "message_type"
        case senderDeviceId          = "sender_device_id"
        case contentHint             = "content_hint"
        case encryptedAttachmentRef  = "encrypted_attachment_ref"
        case parentMessageId         = "parent_message_id"
        case threadName              = "thread_name"
        case deletedAt               = "deleted_at"
        case serverTimestamp         = "server_timestamp"
        case createdAt               = "created_at"
        case senderProfile           = "profiles"
    }

    var isDeleted: Bool { deletedAt != nil }
}

// Post-decryption model — what the UI renders. Never expose DbMessage to views.
struct DecryptedMessage: Identifiable, Hashable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID?
    var content: String
    var messageType: Int
    var contentHint: String?
    var attachmentRef: String?
    var parentMessageId: UUID?
    var threadName: String?
    var deletedAt: Date?
    var serverTimestamp: Date
    var senderProfile: Profile?

    var isDeleted: Bool { deletedAt != nil }
    var isText: Bool { messageType == 3 }
}

struct SendMessageParams: Encodable {
    let conversationId: UUID
    let senderId: UUID
    let encryptedContent: String
    let messageType: Int
    let senderDeviceId: Int
    let contentHint: String?
    let encryptedAttachmentRef: String?
    let parentMessageId: UUID?
    let threadName: String?

    enum CodingKeys: String, CodingKey {
        case conversationId         = "conversation_id"
        case senderId               = "sender_id"
        case encryptedContent       = "encrypted_content"
        case messageType            = "message_type"
        case senderDeviceId         = "sender_device_id"
        case contentHint            = "content_hint"
        case encryptedAttachmentRef = "encrypted_attachment_ref"
        case parentMessageId        = "parent_message_id"
        case threadName             = "thread_name"
    }

    init(
        conversationId: UUID,
        senderId: UUID,
        encryptedContent: String,
        messageType: Int = 3,
        senderDeviceId: Int = 1,
        contentHint: String? = nil,
        encryptedAttachmentRef: String? = nil,
        parentMessageId: UUID? = nil,
        threadName: String? = nil
    ) {
        self.conversationId = conversationId
        self.senderId = senderId
        self.encryptedContent = encryptedContent
        self.messageType = messageType
        self.senderDeviceId = senderDeviceId
        self.contentHint = contentHint
        self.encryptedAttachmentRef = encryptedAttachmentRef
        self.parentMessageId = parentMessageId
        self.threadName = threadName
    }
}
