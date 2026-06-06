import Supabase
import Foundation
import Supabase
import PostgREST

final class ConversationRepository {

    // Mirrors fetchConversations in src/features/chat/api/conversations.ts
    func fetchConversations(userId: UUID) async throws -> [ConversationListItem] {
        // Step 1: fetch membership rows with nested conversation + members + profiles
        struct MembershipRow: Decodable {
            let isMuted: Bool
            let mutedUntil: Date?
            let lastReadAt: Date?
            let conversations: ConvNested?

            enum CodingKeys: String, CodingKey {
                case isMuted = "is_muted"
                case mutedUntil = "muted_until"
                case lastReadAt = "last_read_at"
                case conversations
            }

            struct ConvNested: Decodable {
                let id: UUID
                let name: String?
                let isGroup: Bool
                let avatarUrl: String?
                let updatedAt: Date
                let conversationMembers: [MemberNested]

                enum CodingKeys: String, CodingKey {
                    case id, name
                    case isGroup = "is_group"
                    case avatarUrl = "avatar_url"
                    case updatedAt = "updated_at"
                    case conversationMembers = "conversation_members"
                }

                struct MemberNested: Decodable {
                    let userId: UUID
                    let isAdmin: Bool
                    let isMuted: Bool
                    let lastReadAt: Date?
                    let profiles: Profile?

                    enum CodingKeys: String, CodingKey {
                        case isAdmin = "is_admin"
                        case isMuted = "is_muted"
                        case lastReadAt = "last_read_at"
                        case userId = "user_id"
                        case profiles
                    }
                }
            }
        }

        let memberships: [MembershipRow] = try await supabase
            .from("conversation_members")
            .select("""
                is_muted,
                muted_until,
                last_read_at,
                conversations(
                    id,
                    name,
                    is_group,
                    avatar_url,
                    updated_at,
                    conversation_members(
                        user_id,
                        is_admin,
                        is_muted,
                        last_read_at,
                        profiles(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)
                    )
                )
            """)
            .eq("user_id", value: userId.uuidString)
            .order("updated_at", ascending: false, referencedTable: "conversations")
            .execute()
            .value

        // Step 2: fetch last message per conversation
        let convIds = memberships.compactMap { $0.conversations?.id.uuidString }

        struct LastMsgRow: Decodable, Identifiable {
            let id: UUID
            let conversationId: UUID
            let senderId: UUID?
            let encryptedContent: String
            let messageType: Int
            let contentHint: String?
            let encryptedAttachmentRef: String?
            let parentMessageId: UUID?
            let threadName: String?
            let deletedAt: Date?
            let serverTimestamp: Date

            enum CodingKeys: String, CodingKey {
                case id
                case conversationId = "conversation_id"
                case senderId = "sender_id"
                case encryptedContent = "encrypted_content"
                case messageType = "message_type"
                case contentHint = "content_hint"
                case encryptedAttachmentRef = "encrypted_attachment_ref"
                case parentMessageId = "parent_message_id"
                case threadName = "thread_name"
                case deletedAt = "deleted_at"
                case serverTimestamp = "server_timestamp"
            }
        }

        var lastMessages: [UUID: DecryptedMessage] = [:]
        if !convIds.isEmpty {
            let msgs: [LastMsgRow] = try await supabase
                .from("messages")
                .select("id, conversation_id, sender_id, encrypted_content, message_type, content_hint, encrypted_attachment_ref, parent_message_id, thread_name, deleted_at, server_timestamp")
                .in("conversation_id", values: convIds)
                .is("deleted_at", value: "null")
                .order("server_timestamp", ascending: false)
                .execute()
                .value

            var seen = Set<UUID>()
            for m in msgs {
                guard !seen.contains(m.conversationId) else { continue }
                seen.insert(m.conversationId)
                // Last message in list uses legacy base64 fallback — not worth deriving shared key here
                let content = Data(base64Encoded: m.encryptedContent)
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? m.encryptedContent
                lastMessages[m.conversationId] = DecryptedMessage(
                    id: m.id,
                    conversationId: m.conversationId,
                    senderId: m.senderId,
                    content: content,
                    messageType: m.messageType,
                    contentHint: m.contentHint,
                    attachmentRef: m.encryptedAttachmentRef,
                    parentMessageId: m.parentMessageId,
                    threadName: m.threadName,
                    deletedAt: m.deletedAt,
                    serverTimestamp: m.serverTimestamp
                )
            }
        }

        return memberships.compactMap { row -> ConversationListItem? in
            guard let conv = row.conversations else { return nil }

            let members: [MemberSummary] = conv.conversationMembers.compactMap { cm in
                guard let profile = cm.profiles else { return nil }
                return MemberSummary(
                    userId: cm.userId,
                    profile: profile,
                    isAdmin: cm.isAdmin,
                    isMuted: cm.isMuted,
                    lastReadAt: cm.lastReadAt
                )
            }

            return ConversationListItem(
                id: conv.id,
                name: conv.name,
                isGroup: conv.isGroup,
                avatarUrl: conv.avatarUrl,
                members: members,
                lastMessage: lastMessages[conv.id],
                unreadCount: row.lastReadAt == nil && lastMessages[conv.id] != nil ? 1 : 0,
                isMuted: row.isMuted,
                mutedUntil: row.mutedUntil,
                updatedAt: conv.updatedAt
            )
        }
    }

    // Mirrors createDirectConversation
    func createDirectConversation(userId: UUID, otherUserId: UUID) async throws -> UUID {
        // Check for existing via RPC
        struct RPCResult: Decodable { let id: UUID? }
        if let existing = try? await supabase
            .rpc("find_direct_conversation", params: ["user_a": userId.uuidString, "user_b": otherUserId.uuidString])
            .execute()
            .value as UUID? {
            return existing
        }

        struct NewConv: Decodable { let id: UUID }
        let conv: NewConv = try await supabase
            .from("conversations")
            .insert(["is_group": false, "created_by": userId.uuidString])
            .select("id")
            .single()
            .execute()
            .value

        struct MemberInsert: Encodable {
            let conversation_id: String
            let user_id: String
            let is_admin: Bool
        }

        try await supabase
            .from("conversation_members")
            .insert([
                MemberInsert(conversation_id: conv.id.uuidString, user_id: userId.uuidString, is_admin: true),
                MemberInsert(conversation_id: conv.id.uuidString, user_id: otherUserId.uuidString, is_admin: false),
            ])
            .execute()

        return conv.id
    }

    // Mirrors createGroupConversation
    func createGroupConversation(userId: UUID, memberIds: [UUID], name: String) async throws -> UUID {
        struct NewConv: Decodable { let id: UUID }
        let conv: NewConv = try await supabase
            .from("conversations")
            .insert(["is_group": true, "name": name, "created_by": userId.uuidString])
            .select("id")
            .single()
            .execute()
            .value

        struct MemberInsert: Encodable {
            let conversation_id: String
            let user_id: String
            let is_admin: Bool
        }

        let allIds = Array(Set([userId] + memberIds))
        let inserts = allIds.map {
            MemberInsert(conversation_id: conv.id.uuidString, user_id: $0.uuidString, is_admin: $0 == userId)
        }
        try await supabase.from("conversation_members").insert(inserts).execute()
        return conv.id
    }

    // Mirrors searchUsers
    func searchUsers(query: String, excluding userId: UUID) async throws -> [Profile] {
        return try await supabase
            .from("profiles")
            .select("id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at")
            .ilike("username", value: "%\(query)%")
            .neq("id", value: userId.uuidString)
            .limit(20)
            .execute()
            .value
    }

    // Mirrors muteConversation
    func muteConversation(conversationId: UUID, userId: UUID, until: Date?) async throws {
        struct MuteUpdate: Encodable {
            let is_muted: Bool
            let muted_until: String?
        }
        try await supabase
            .from("conversation_members")
            .update(MuteUpdate(is_muted: until != nil, muted_until: until?.iso8601))
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    // Mirrors markConversationRead
    func markRead(conversationId: UUID, userId: UUID) async throws {
        try await supabase
            .from("conversation_members")
            .update(["last_read_at": Date().iso8601])
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }
}
