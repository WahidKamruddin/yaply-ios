import Supabase
import Foundation

final class MessageRepository {
    private let pageSize = 50

    // Mirrors fetchMessages in src/features/chat/api/messages.ts
    func fetchMessages(conversationId: UUID, cursor: Date? = nil) async throws -> (messages: [DbMessage], nextCursor: Date?) {
        var query = supabase
            .from("messages")
            .select("""
                id,
                conversation_id,
                sender_id,
                encrypted_content,
                message_type,
                sender_device_id,
                content_hint,
                encrypted_attachment_ref,
                parent_message_id,
                thread_name,
                deleted_at,
                server_timestamp,
                created_at,
                profiles!messages_sender_id_fkey(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)
            """)
            .eq("conversation_id", value: conversationId.uuidString)
            .order("server_timestamp", ascending: false)
            .limit(pageSize)

        if let cursor {
            query = query.lt("server_timestamp", value: cursor.iso8601)
        }

        let messages: [DbMessage] = try await query.execute().value
        let nextCursor = messages.count == pageSize ? messages.last?.serverTimestamp : nil
        return (messages, nextCursor)
    }

    func sendMessage(_ params: SendMessageParams) async throws -> DbMessage {
        return try await supabase
            .from("messages")
            .insert(params)
            .select("""
                id,
                conversation_id,
                sender_id,
                encrypted_content,
                message_type,
                sender_device_id,
                content_hint,
                encrypted_attachment_ref,
                parent_message_id,
                thread_name,
                deleted_at,
                server_timestamp,
                created_at
            """)
            .single()
            .execute()
            .value
    }

    func softDelete(messageId: UUID) async throws {
        try await supabase
            .from("messages")
            .update(["deleted_at": Date().iso8601])
            .eq("id", value: messageId.uuidString)
            .execute()
    }
}
