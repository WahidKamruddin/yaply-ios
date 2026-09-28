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
                enc_v,
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
                enc_v,
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

    /// Posts the "{sender} created a {kind} · {title}" pill. Best effort: a
    /// failed pill must never fail the create itself. System messages are
    /// never encrypted (`iv: nil`, `enc_v: nil`, base64 UTF-8 content) and
    /// self-destruct after a week via `deleted_at`, exactly like web's
    /// `postItemCreated`.
    static func postItemCreated(conversationId: UUID, senderId: UUID, item: SystemItem) async {
        struct Row: Encodable {
            let conversation_id: String
            let sender_id: String
            let content: String
            let iv: String?
            let type: String
            let deleted_at: String
        }
        let row = Row(
            conversation_id: conversationId.uuidString,
            sender_id: senderId.uuidString,
            content: Data(item.encoded.utf8).base64EncodedString(),
            iv: nil,
            type: "system",
            deleted_at: Date().addingTimeInterval(7 * 24 * 60 * 60).iso8601
        )
        do {
            try await supabase.from("messages").insert(row).execute()
        } catch {
            print("[yaply] failed to post item-created message: \(error)")
        }
    }

    // Every registered device of every given user, active or not — read through
    // `DeviceListCache`, never directly by the send path. One query answers both
    // "does this member have any device at all" (the phase-1 fallback, which must
    // ignore last_active_at so a merely stale device doesn't downgrade the whole
    // message) and, filtered to the 90-day window, "which devices get an envelope".
    // Callers must union the sender's id into `userIds` themselves so their own
    // other devices can read their sent message.
    func fetchDeviceRows(userIds: [UUID]) async throws -> [DeviceRow] {
        guard !userIds.isEmpty else { return [] }
        return try await supabase
            .from("devices")
            .select("user_id, device_id, identity_key, key_fingerprint, last_active_at")
            .in("user_id", values: userIds.map(\.uuidString))
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

    // Re-seals an already-sent v2 message — the RPC replaces ALL envelopes
    // atomically, never appends. See ../CLAUDE.md's "Link previews" section.
    func editMessageWithEnvelopes(_ params: EditMessageWithEnvelopesParams) async throws -> DbMessage {
        return try await supabase
            .rpc("edit_message_with_envelopes", params: params)
            .single()
            .execute()
            .value
    }

    // Phase-1 messages have no envelopes to replace atomically, so a plain
    // column update (permitted by messages' "sender can update" RLS policy)
    // is sufficient — mirrors sendMessageWithEnvelopes's phase-1 counterpart.
    func editPhase1Content(messageId: UUID, content: String) async throws {
        struct Row: Encodable {
            let content: String
            let edited_at: String
        }
        try await supabase
            .from("messages")
            .update(Row(content: content, edited_at: Date().iso8601))
            .eq("id", value: messageId.uuidString)
            .execute()
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

    /// Batched form of `fetchEnvelope`, for decrypting a whole page at once.
    ///
    /// Decrypting a 50-message page used to make 50 sequential round-trips --
    /// one per message, each awaited before the next began -- which is the bulk
    /// of the delay when opening a conversation. Same selection rule as the
    /// single-message version: a message can match several candidate
    /// fingerprints, and the earliest candidate wins so this device's own key is
    /// preferred over an escrowed one.
    func fetchEnvelopes(
        messageIds: [UUID],
        candidateFps: [String]
    ) async throws -> [UUID: MessageEnvelope] {
        guard !candidateFps.isEmpty, !messageIds.isEmpty else { return [:] }

        // Chunked so the PostgREST `in` list can't produce an over-long URL.
        var rows: [MessageEnvelope] = []
        for chunk in stride(from: 0, to: messageIds.count, by: 100).map({
            Array(messageIds[$0..<min($0 + 100, messageIds.count)])
        }) {
            let page: [MessageEnvelope] = try await supabase
                .from("message_envelopes")
                .select("message_id, recipient_user_id, recipient_fp, eph_pub, key_iv, wrapped_key")
                .in("message_id", values: chunk.map(\.uuidString))
                .in("recipient_fp", values: candidateFps)
                .execute()
                .value
            rows.append(contentsOf: page)
        }

        let rank = Dictionary(
            uniqueKeysWithValues: candidateFps.enumerated().map { ($1, $0) }
        )
        var best: [UUID: MessageEnvelope] = [:]
        for row in rows {
            guard let mid = row.messageId else { continue }
            let incoming = rank[row.recipientFp] ?? Int.max
            if let existing = best[mid] {
                let current = rank[existing.recipientFp] ?? Int.max
                if incoming < current { best[mid] = row }
            } else {
                best[mid] = row
            }
        }
        return best
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
                enc_v,
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

    // MARK: - Pins

    private struct PinRow: Decodable { let messageId: UUID; enum CodingKeys: String, CodingKey { case messageId = "message_id" } }

    func fetchPinnedMessageIds(conversationId: UUID) async throws -> [UUID] {
        let rows: [PinRow] = try await supabase
            .from("pinned_messages")
            .select("message_id")
            .eq("conversation_id", value: conversationId.uuidString)
            .order("pinned_at", ascending: false)
            .execute()
            .value
        return rows.map(\.messageId)
    }

    func pinMessage(messageId: UUID, conversationId: UUID, userId: UUID) async throws {
        struct Insert: Encodable {
            let conversation_id: String
            let message_id: String
            let pinned_by: String
        }
        try await supabase
            .from("pinned_messages")
            .upsert(
                Insert(conversation_id: conversationId.uuidString,
                       message_id: messageId.uuidString,
                       pinned_by: userId.uuidString),
                onConflict: "conversation_id,message_id"
            )
            .execute()
    }

    func unpinMessage(messageId: UUID, conversationId: UUID) async throws {
        try await supabase
            .from("pinned_messages")
            .delete()
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("message_id", value: messageId.uuidString)
            .execute()
    }
}
