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
