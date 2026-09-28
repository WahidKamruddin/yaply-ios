import Supabase
import Foundation

final class ConversationRepository {

    func fetchConversations(userId: UUID) async throws -> [ConversationListItem] {
        struct MembershipRow: Decodable {
            let lastReadAt: Date?
            let mutedUntil: Date?
            let muteMentions: Bool
            let requestState: String
            let conversations: ConvNested?

            enum CodingKeys: String, CodingKey {
                case lastReadAt = "last_read_at"
                case mutedUntil = "muted_until"
                case muteMentions = "mute_mentions"
                case requestState = "request_state"
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

        // Both queries run concurrently: memberships (with member profiles) and
        // the per-conversation last message + unread counts.
        async let membershipsQuery: [MembershipRow] = supabase
            .from("conversation_members")
            .select("""
                last_read_at,
                muted_until,
                mute_mentions,
                request_state,
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

        async let summariesQuery: [ConversationSummaryRow] = supabase
            .rpc("get_conversation_summaries")
            .execute()
            .value
        let (memberships, summaries) = try await (membershipsQuery, summariesQuery)

        // get_conversation_summaries replaced a query that selected every
        // non-deleted message in every conversation (no limit) and counted
        // unreads here — run on every realtime insert and presence change. Its
        // unread rule matches the push badge's (00045): no system messages,
        // nothing from me or a deleted sender, only after my last_read_at.
        var lastMessages: [UUID: DecryptedMessage] = [:]
        var unreadCounts: [UUID: Int] = [:]
        var mentionUnreadCounts: [UUID: Int] = [:]
        for row in summaries {
            unreadCounts[row.conversationId] = row.unreadCount
            mentionUnreadCounts[row.conversationId] = row.mentionUnreadCount
            guard let id = row.lastMessageId, let createdAt = row.lastCreatedAt else { continue }
            lastMessages[row.conversationId] = DecryptedMessage(
                id: id,
                conversationId: row.conversationId,
                senderId: row.lastSenderId,
                content: "",
                type: row.lastType ?? "text",
                createdAt: createdAt
            )
        }
        await decryptPreviews(summaries, into: &lastMessages, userId: userId)

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
            let mentionUnreadCount = mentionUnreadCounts[conv.id] ?? 0
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
                updatedAt: conv.updatedAt,
                requestState: row.requestState,
                mentionUnreadCount: mentionUnreadCount,
                muteMentions: row.muteMentions
            )
        }
        .sorted {
            let aTime = $0.lastMessage?.createdAt ?? $0.updatedAt
            let bTime = $1.lastMessage?.createdAt ?? $1.updatedAt
            return aTime > bTime
        }
    }

    /// Sidebar previews, branched exactly like every other decrypt site: enc_v
    /// first, then iv. v2 previews share one batched envelope query. This used
    /// to show the raw base64 ciphertext of any encrypted last message.
    private func decryptPreviews(
        _ rows: [ConversationSummaryRow],
        into lastMessages: inout [UUID: DecryptedMessage],
        userId: UUID
    ) async {
        let v2 = rows.filter { $0.lastEncV == 2 && $0.lastMessageId != nil }
        var envelopes: [UUID: MessageEnvelope] = [:]
        if !v2.isEmpty {
            try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: userId)
            envelopes = (try? await MessageRepository().fetchEnvelopes(
                messageIds: v2.compactMap(\.lastMessageId),
                candidateFps: KeyStore.candidateFingerprints(forUser: userId)
            )) ?? [:]
        }

        for row in rows {
            guard let id = row.lastMessageId, var message = lastMessages[row.conversationId] else { continue }
            let content = row.lastContent ?? ""
            if row.lastEncV == 2 {
                if let iv = row.lastIv, let envelope = envelopes[id],
                   let plaintext = EnvelopeEncryption.open(envelope: envelope, content: content, iv: iv, userId: userId) {
                    message.content = plaintext
                } else {
                    message.decryptFailed = true
                }
            } else if row.lastEncV == nil && row.lastIv == nil {
                message.content = EncryptionService.decryptLegacy(content) ?? content
            } else {
                message.decryptFailed = true
            }
            // Only type="text" ever carries a link-preview envelope.
            if !message.decryptFailed, message.type == "text" {
                let decoded = LinkPreviewCodec.decodeTextMessage(message.content)
                message.content = decoded.text
                message.linkPreview = decoded.linkPreview
            }
            lastMessages[row.conversationId] = message
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
        struct Params: Encodable {
            let p_name: String
            let p_member_ids: [String]
        }
        let others = memberIds.filter { $0 != userId }.map { $0.uuidString }
        let convId: UUID = try await supabase
            .rpc("create_group_conversation", params: Params(p_name: name.isEmpty ? "Group" : name, p_member_ids: others))
            .execute()
            .value
        return convId
    }

    func muteConversation(conversationId: UUID, userId: UUID, until: Date?, muteMentions: Bool = false) async throws {
        // Explicit AnyJSON.null rather than an Encodable struct holding an
        // Optional: JSONEncoder omits nil Optionals, so unmuting sent an empty
        // PATCH body and silently did nothing while muting worked fine.
        // Unmuting always resets mute_mentions too — it's meaningless while
        // muted_until is nil.
        let payload: [String: AnyJSON] = [
            "muted_until": until.map { .string($0.iso8601) } ?? .null,
            "mute_mentions": .bool(until == nil ? false : muteMentions)
        ]
        try await supabase
            .from("conversation_members")
            .update(payload)
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

    func promoteMemberToAdmin(conversationId: UUID, targetUserId: UUID) async throws {
        struct RoleUpdate: Encodable { let role: String }
        try await supabase
            .from("conversation_members")
            .update(RoleUpdate(role: "admin"))
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: targetUserId.uuidString)
            .execute()
    }

    func deleteGroupForEveryone(conversationId: UUID) async throws {
        try await supabase
            .from("conversations")
            .delete()
            .eq("id", value: conversationId.uuidString)
            .execute()
    }

    /// Advances my read (and delivery) watermark in one conversation to the
    /// server's now(). Server clock on purpose: a device clock running behind
    /// never reached a message's created_at, so it could never show as seen.
    func markRead(conversationId: UUID) async throws {
        try await supabase
            .rpc("mark_conversation_read", params: ["p_conversation_id": conversationId.uuidString])
            .execute()
    }

    /// Advances my delivery watermark in every conversation to `until` — the
    /// newest created_at this device has actually received. Forward-only and a
    /// no-op when nothing would change.
    func markDelivered(until: Date) async throws {
        try await supabase
            .rpc("mark_delivered", params: ["p_until": until.iso8601])
            .execute()
    }
}

/// One row of `get_conversation_summaries()`: the caller's conversation, its
/// newest live message (still ciphertext) and raw unread counts. Mute and
/// request_state are applied by the list, not the RPC.
struct ConversationSummaryRow: Decodable {
    let conversationId: UUID
    let lastMessageId: UUID?
    let lastSenderId: UUID?
    let lastContent: String?
    let lastIv: String?
    let lastEncV: Int?
    let lastType: String?
    let lastCreatedAt: Date?
    let unreadCount: Int
    let mentionUnreadCount: Int

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case lastMessageId = "last_message_id"
        case lastSenderId = "last_sender_id"
        case lastContent = "last_content"
        case lastIv = "last_iv"
        case lastEncV = "last_enc_v"
        case lastType = "last_type"
        case lastCreatedAt = "last_created_at"
        case unreadCount = "unread_count"
        case mentionUnreadCount = "mention_unread_count"
    }
}
