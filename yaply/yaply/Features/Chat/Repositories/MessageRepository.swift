import Foundation
import Supabase

final class MessageRepository {
    private let pageSize = 50

    func fetchMessages(conversationId: UUID, cursor: Date? = nil) async throws -> (messages: [DbMessage], nextCursor: Date?) {
        let baseQuery = supabase
            .from("messages")
            .select("""
                id,
                conversation_id,
                sender_id,
                content,
                iv,
                type,
                media_url,
                media_mime,
                reply_to_id,
                thread_id,
                edited_at,
                deleted_at,
                created_at,
                profiles!messages_sender_id_fkey(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)
            """)
            .eq("conversation_id", value: conversationId.uuidString)

        let messages: [DbMessage]

        if let cursor {
            messages = try await baseQuery
                .lt("created_at", value: cursor.iso8601)
                .order("created_at", ascending: false)
                .limit(pageSize)
                .execute()
                .value
        } else {
            messages = try await baseQuery
                .order("created_at", ascending: false)
                .limit(pageSize)
                .execute()
                .value
        }

        let nextCursor = messages.count == pageSize ? messages.last?.createdAt : nil
        return (messages, nextCursor)
    }

    func fetchMessagesSince(conversationId: UUID, after: Date) async throws -> [DbMessage] {
        return try await supabase
            .from("messages")
            .select("""
                id,
                conversation_id,
                sender_id,
                content,
                iv,
                type,
                media_url,
                media_mime,
                reply_to_id,
                thread_id,
                edited_at,
                deleted_at,
                created_at,
                profiles!messages_sender_id_fkey(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)
            """)
            .eq("conversation_id", value: conversationId.uuidString)
            .gt("created_at", value: after.iso8601)
            .order("created_at", ascending: false)
            .limit(20)
            .execute()
            .value
    }

    // Plain insert — ONLY for phase-1 fallback (no member has a registered device
    // yet) and media/sticker/gif/system rows, which are never encrypted
    // (`content: "", iv: nil, enc_v: nil`). Encrypted text sends must go through
    // `sendMessageWithEnvelopes` instead, which is the only path allowed to write
    // `enc_v = 2`.
    func sendMessage(_ params: SendMessageParams) async throws -> DbMessage {
        return try await supabase
            .from("messages")
            .insert(params)
            .select("""
                id,
                conversation_id,
                sender_id,
                content,
                iv,
                enc_v,
                type,
                media_url,
                media_mime,
                reply_to_id,
                thread_id,
                edited_at,
                deleted_at,
                created_at
            """)
            .single()
            .execute()
            .value
    }

    // Unfiltered by last_active_at — used ONLY to decide the phase-1 fallback
    // (does this member have any registered device at all, ever). Must NOT be used
    // to pick which devices receive envelopes; a member with a merely stale device
    // should have that device excluded from the send, not trigger a fallback for
    // the whole message.
    func fetchUserIdsWithAnyDevice(userIds: [UUID]) async throws -> Set<UUID> {
        guard !userIds.isEmpty else { return [] }
        struct Row: Decodable {
            let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        let rows: [Row] = try await supabase
            .from("devices")
            .select("user_id")
            .in("user_id", values: userIds.map(\.uuidString))
            .execute()
            .value
        return Set(rows.map(\.userId))
    }

    // Every active device (last_active_at within 90 days) of every given user,
    // including the sender's own — callers must union the sender's id into
    // `userIds` themselves so their own other devices can read their sent message.
    func fetchActiveDeviceRows(userIds: [UUID]) async throws -> [DeviceRow] {
        guard !userIds.isEmpty else { return [] }
        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60).iso8601
        return try await supabase
            .from("devices")
            .select("user_id, device_id, identity_key, key_fingerprint, last_active_at")
            .in("user_id", values: userIds.map(\.uuidString))
            .gt("last_active_at", value: cutoff)
            .execute()
            .value
    }

    // The only way to insert an encrypted (enc_v=2) message — writes the message
    // row and all `message_envelopes` rows atomically; rejects an empty envelope
    // array or a NULL iv server-side.
    func sendMessageWithEnvelopes(_ params: SendMessageWithEnvelopesParams) async throws -> DbMessage {
        return try await supabase
            .rpc("send_message_with_envelopes", params: params)
            .single()
            .execute()
            .value
    }

    // Fetches an envelope this install can open. `candidateFps` is this device's
    // own fingerprint plus any escrowed ones adopted via live pairing (see
    // KeyStore.candidateFingerprints) — a message sealed before this device
    // existed only has an envelope for an escrowed fingerprint, which is exactly
    // what makes history readable after pairing. No row is a legitimate,
    // permanent state, not an error.
    func fetchEnvelope(messageId: UUID, candidateFps: [String]) async throws -> MessageEnvelope? {
        guard !candidateFps.isEmpty else { return nil }
        let rows: [MessageEnvelope] = try await supabase
            .from("message_envelopes")
            .select("message_id, recipient_user_id, recipient_fp, eph_pub, key_iv, wrapped_key")
            .eq("message_id", value: messageId.uuidString)
            .in("recipient_fp", values: candidateFps)
            .execute()
            .value
        // A message can match more than one candidate (this device *and* an
        // escrowed one both received envelopes). Prefer the earliest fingerprint
        // in the list — candidateFingerprints puts this device's own key first,
        // so we decrypt with the local key whenever that's an option.
        for fp in candidateFps {
            if let match = rows.first(where: { $0.recipientFp == fp }) { return match }
        }
        return rows.first
    }

    func softDelete(messageId: UUID) async throws {
        struct DeleteUpdate: Encodable { let deleted_at: String }
        try await supabase
            .from("messages")
            .update(DeleteUpdate(deleted_at: Date().iso8601))
            .eq("id", value: messageId.uuidString)
            .execute()
    }

    func fetchThreadMessages(threadRootId: UUID) async throws -> [DbMessage] {
        return try await supabase
            .from("messages")
            .select("""
                id,
                conversation_id,
                sender_id,
                content,
                iv,
                type,
                media_url,
                media_mime,
                reply_to_id,
                thread_id,
                edited_at,
                deleted_at,
                created_at,
                profiles!messages_sender_id_fkey(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)
            """)
            .eq("thread_id", value: threadRootId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    // MARK: - Read receipts

    func insertReadReceipts(_ messageIds: [UUID], userId: UUID) async throws {
        guard !messageIds.isEmpty else { return }
        struct Insert: Encodable {
            let message_id: String
            let user_id: String
        }
        try await supabase
            .from("message_reads")
            .upsert(
                messageIds.map { Insert(message_id: $0.uuidString, user_id: userId.uuidString) },
                onConflict: "message_id,user_id"
            )
            .execute()
    }

    func fetchReadSet(messageIds: [UUID], currentUserId: UUID) async throws -> Set<UUID> {
        guard !messageIds.isEmpty else { return [] }
        struct ReadRow: Decodable {
            let messageId: UUID
            enum CodingKeys: String, CodingKey { case messageId = "message_id" }
        }
        let rows: [ReadRow] = try await supabase
            .from("message_reads")
            .select("message_id")
            .in("message_id", values: messageIds.map(\.uuidString))
            .neq("user_id", value: currentUserId.uuidString)
            .execute()
            .value
        return Set(rows.map(\.messageId))
    }

    // MARK: - Reactions

    func fetchReactions(messageIds: [UUID]) async throws -> [Reaction] {
        guard !messageIds.isEmpty else { return [] }
        return try await supabase
            .from("message_reactions")
            .select("message_id, user_id, emoji")
            .in("message_id", values: messageIds.map(\.uuidString))
            .execute()
            .value
    }

    func addReaction(messageId: UUID, userId: UUID, emoji: String) async throws {
        struct Insert: Encodable {
            let message_id: String
            let user_id: String
            let emoji: String
        }
        try await supabase
            .from("message_reactions")
            .upsert(
                Insert(message_id: messageId.uuidString, user_id: userId.uuidString, emoji: emoji),
                onConflict: "message_id,user_id,emoji"
            )
            .execute()
    }

    func removeReaction(messageId: UUID, userId: UUID, emoji: String) async throws {
        try await supabase
            .from("message_reactions")
            .delete()
            .eq("message_id", value: messageId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .eq("emoji", value: emoji)
            .execute()
    }
}
