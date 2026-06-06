import Supabase
import Foundation

final class ConversationRepository {

    func fetchConversations(userId: UUID) async throws -> [ConversationListItem] {
        struct MembershipRow: Decodable {
            let lastReadAt: Date?
            let mutedUntil: Date?
            let conversations: ConvNested?

            enum CodingKeys: String, CodingKey {
                case lastReadAt = "last_read_at"
                case mutedUntil = "muted_until"
                case conversations
            }

            struct ConvNested: Decodable {
                let id: UUID
                let name: String?
                let type: String
                let avatarUrl: String?
                let updatedAt: Date
                let conversationMembers: [MemberNested]

                enum CodingKeys: String, CodingKey {
                    case id, name, type
                    case avatarUrl = "avatar_url"
                    case updatedAt = "updated_at"
                    case conversationMembers = "conversation_members"
                }

                struct MemberNested: Decodable {
                    let userId: UUID
                    let role: String
                    let lastReadAt: Date?
                    let profiles: Profile?

                    enum CodingKeys: String, CodingKey {
                        case userId = "user_id"
                        case role
                        case lastReadAt = "last_read_at"
                        case profiles
                    }
                }
            }
        }

        let memberships: [MembershipRow] = try await supabase
            .from("conversation_members")
            .select("""
                last_read_at,
                muted_until,
                conversations(
                    id,
                    name,
                    type,
                    avatar_url,
                    updated_at,
                    conversation_members(
                        user_id,
                        role,
                        last_read_at,
                        profiles(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)
                    )
                )
            """)
            .eq("user_id", value: userId.uuidString)
            .order("updated_at", ascending: false, referencedTable: "conversations")
            .execute()
            .value

        let convIds = memberships.compactMap { $0.conversations?.id.uuidString }

        struct LastMsgRow: Decodable, Identifiable {
            let id: UUID
            let conversationId: UUID
            let senderId: UUID?
            let content: String
            let iv: String?
            let type: String
            let deletedAt: Date?
            let createdAt: Date

            enum CodingKeys: String, CodingKey {
                case id
                case conversationId = "conversation_id"
                case senderId = "sender_id"
                case content, iv, type
                case deletedAt = "deleted_at"
                case createdAt = "created_at"
            }
        }

        // Map convId → my last_read_at for unread counting
        var myLastReadAt: [UUID: Date] = [:]
        for row in memberships {
            if let convId = row.conversations?.id, let lastRead = row.lastReadAt {
                myLastReadAt[convId] = lastRead
            }
        }

        var lastMessages: [UUID: DecryptedMessage] = [:]
        var unreadCounts: [UUID: Int] = [:]

        if !convIds.isEmpty {
            let msgs: [LastMsgRow] = try await supabase
                .from("messages")
                .select("id, conversation_id, sender_id, content, iv, type, deleted_at, created_at")
                .in("conversation_id", values: convIds)
                .is("deleted_at", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value

            var seen = Set<UUID>()
            for m in msgs {
                if !seen.contains(m.conversationId) {
                    seen.insert(m.conversationId)
                    let preview: String
                    if m.iv == nil {
                        preview = Data(base64Encoded: m.content).flatMap { String(data: $0, encoding: .utf8) } ?? m.content
                    } else {
                        preview = m.content
                    }
                    lastMessages[m.conversationId] = DecryptedMessage(
                        id: m.id,
                        conversationId: m.conversationId,
                        senderId: m.senderId,
                        content: preview,
                        type: m.type,
                        deletedAt: m.deletedAt,
                        createdAt: m.createdAt
                    )
                }

                // Count messages from others after my last read timestamp
                if m.senderId != userId {
                    let lastRead = myLastReadAt[m.conversationId]
                    if lastRead == nil || m.createdAt > lastRead! {
                        unreadCounts[m.conversationId, default: 0] += 1
                    }
                }
            }
        }

        return memberships.compactMap { row -> ConversationListItem? in
            guard let conv = row.conversations else { return nil }

            let members: [MemberSummary] = conv.conversationMembers.compactMap { cm in
                guard let profile = cm.profiles else { return nil }
                return MemberSummary(
                    userId: cm.userId,
                    profile: profile,
                    isAdmin: cm.role == "owner" || cm.role == "admin",
                    isMuted: false,
                    lastReadAt: cm.lastReadAt
                )
            }

            let lastMsg = lastMessages[conv.id]
            let unreadCount = unreadCounts[conv.id] ?? 0
            let mutedUntil = row.mutedUntil
            let isMuted = mutedUntil.map { $0 > Date() } ?? false
            return ConversationListItem(
                id: conv.id,
                name: conv.name,
                isGroup: conv.type == "group",
                avatarUrl: conv.avatarUrl,
                members: members,
                lastMessage: lastMsg,
                unreadCount: unreadCount,
                isMuted: isMuted,
                mutedUntil: mutedUntil,
                updatedAt: conv.updatedAt
            )
        }
        .sorted {
            let aTime = $0.lastMessage?.createdAt ?? $0.updatedAt
            let bTime = $1.lastMessage?.createdAt ?? $1.updatedAt
            return aTime > bTime
        }
    }

    // Uses find_or_create_direct_conversation RPC (security definer — handles RLS correctly).
    func createDirectConversation(userId: UUID, otherUserId: UUID) async throws -> UUID {
        let convId: UUID = try await supabase
            .rpc("find_or_create_direct_conversation", params: ["target_user_id": otherUserId.uuidString])
            .execute()
            .value
        return convId
    }

    func createGroupConversation(userId: UUID, memberIds: [UUID], name: String) async throws -> UUID {
        struct NewConv: Decodable { let id: UUID }
        struct GroupConvInsert: Encodable {
            let type: String
            let name: String
            let created_by: String
        }
        let conv: NewConv = try await supabase
            .from("conversations")
            .insert(GroupConvInsert(type: "group", name: name, created_by: userId.uuidString))
            .select("id")
            .single()
            .execute()
            .value

        struct MemberInsert: Encodable {
            let conversation_id: String
            let user_id: String
            let role: String
        }

        // Insert creator first (RLS policy requires them to exist as owner before others can be added)
        try await supabase
            .from("conversation_members")
            .insert(MemberInsert(conversation_id: conv.id.uuidString, user_id: userId.uuidString, role: "owner"))
            .execute()

        let others = memberIds.filter { $0 != userId }
        if !others.isEmpty {
            try await supabase
                .from("conversation_members")
                .insert(others.map { MemberInsert(conversation_id: conv.id.uuidString, user_id: $0.uuidString, role: "member") })
                .execute()
        }

        return conv.id
    }

    func searchUsers(query: String, excluding userId: UUID) async throws -> [Profile] {
        return try await supabase
            .from("profiles")
            .select("id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at")
            .ilike("username", pattern: "%\(query)%")
            .neq("id", value: userId.uuidString)
            .limit(20)
            .execute()
            .value
    }

    func muteConversation(conversationId: UUID, userId: UUID, until: Date?) async throws {
        struct MuteUpdate: Encodable { let muted_until: String? }
        try await supabase
            .from("conversation_members")
            .update(MuteUpdate(muted_until: until?.iso8601))
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    func addGroupMember(conversationId: UUID, userId: UUID) async throws {
        struct MemberInsert: Encodable {
            let conversation_id: String
            let user_id: String
            let role: String
        }
        try await supabase
            .from("conversation_members")
            .upsert(
                MemberInsert(conversation_id: conversationId.uuidString, user_id: userId.uuidString, role: "member"),
                onConflict: "conversation_id,user_id"
            )
            .execute()
    }

    func removeGroupMember(conversationId: UUID, userId: UUID) async throws {
        try await supabase
            .from("conversation_members")
            .delete()
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    func deleteConversation(conversationId: UUID, userId: UUID) async throws {
        try await supabase
            .from("conversation_members")
            .delete()
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    func markRead(conversationId: UUID, userId: UUID) async throws {
        struct ReadUpdate: Encodable {
            let last_read_at: String
        }
        try await supabase
            .from("conversation_members")
            .update(ReadUpdate(last_read_at: Date().iso8601))
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }
}
