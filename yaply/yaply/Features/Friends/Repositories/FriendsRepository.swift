import Supabase
import Foundation

// Data layer for the Friends system (migration 00033_friends_system.sql).
// friendships has no INSERT/UPDATE RLS policy — every write here that isn't a
// plain DELETE goes through a SECURITY DEFINER RPC. See yaply-ios/CLAUDE.md's
// "Friends System" section for the full contract.
final class FriendsRepository {

    private static let profileColumns =
        "id, username, display_name, avatar_url, bio, public_key, is_online, last_seen_at, created_at, updated_at, birthdate"

    // MARK: - Friends / requests

    private struct FriendshipRow: Decodable {
        let id: UUID
        let requesterId: UUID
        let recipientId: UUID
        let status: String
        let createdAt: Date
        let updatedAt: Date
        let requester: Profile?
        let recipient: Profile?

        enum CodingKeys: String, CodingKey {
            case id, status, requester, recipient
            case requesterId = "requester_id"
            case recipientId = "recipient_id"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    // Two FKs from friendships to profiles (requester_id, recipient_id) — the
    // embed needs an explicit FK hint or PostgREST can't disambiguate the join.
    private func fetchFriendshipRows(userId: UUID) async throws -> [FriendshipRow] {
        try await supabase
            .from("friendships")
            .select("""
                id, requester_id, recipient_id, status, created_at, updated_at,
                requester:profiles!friendships_requester_id_fkey(\(Self.profileColumns)),
                recipient:profiles!friendships_recipient_id_fkey(\(Self.profileColumns))
            """)
            .or("requester_id.eq.\(userId.uuidString),recipient_id.eq.\(userId.uuidString)")
            .execute()
            .value
    }

    func fetchFriends(userId: UUID) async throws -> [Friend] {
        let rows = try await fetchFriendshipRows(userId: userId)
        return rows.compactMap { row in
            guard row.status == "accepted" else { return nil }
            let isMine = row.requesterId == userId
            guard let other = isMine ? row.recipient : row.requester else { return nil }
            return Friend(friendshipId: row.id, profile: other, since: row.updatedAt)
        }
    }

    func fetchFriendRequests(userId: UUID) async throws -> (incoming: [FriendRequest], outgoing: [FriendRequest]) {
        let rows = try await fetchFriendshipRows(userId: userId)
        var incoming: [FriendRequest] = []
        var outgoing: [FriendRequest] = []
        for row in rows where row.status == "pending" {
            if row.recipientId == userId, let profile = row.requester {
                incoming.append(FriendRequest(id: row.id, profile: profile, direction: .incoming, createdAt: row.createdAt))
            } else if row.requesterId == userId, let profile = row.recipient {
                outgoing.append(FriendRequest(id: row.id, profile: profile, direction: .outgoing, createdAt: row.createdAt))
            }
        }
        return (incoming, outgoing)
    }

    func sendFriendRequest(recipientId: UUID) async throws {
        try await supabase
            .rpc("send_friend_request", params: ["p_recipient_id": recipientId.uuidString])
            .execute()
    }

    func acceptFriendRequest(requestId: UUID) async throws {
        try await supabase
            .rpc("accept_friend_request", params: ["p_request_id": requestId.uuidString])
            .execute()
    }

    // Covers decline, cancel and unfriend — all three are the same DELETE.
    func removeFriendship(friendshipId: UUID) async throws {
        try await supabase
            .from("friendships")
            .delete()
            .eq("id", value: friendshipId.uuidString)
            .execute()
    }

    // MARK: - Blocking

    func blockUser(userId: UUID) async throws {
        try await supabase
            .rpc("block_user", params: ["p_user_id": userId.uuidString])
            .execute()
    }

    func unblockUser(blockerId: UUID, blockedId: UUID) async throws {
        try await supabase
            .from("user_blocks")
            .delete()
            .eq("blocker_id", value: blockerId.uuidString)
            .eq("blocked_id", value: blockedId.uuidString)
            .execute()
    }

    func fetchBlockedUsers(userId: UUID) async throws -> [BlockedUser] {
        struct BlockRow: Decodable {
            let blockedId: UUID
            let createdAt: Date
            let blocked: Profile?
            enum CodingKeys: String, CodingKey {
                case blockedId = "blocked_id"
                case createdAt = "created_at"
                case blocked
            }
        }
        let rows: [BlockRow] = try await supabase
            .from("user_blocks")
            .select("blocked_id, created_at, blocked:profiles!user_blocks_blocked_id_fkey(\(Self.profileColumns))")
            .eq("blocker_id", value: userId.uuidString)
            .execute()
            .value
        return rows.compactMap { row in
            guard let profile = row.blocked else { return nil }
            return BlockedUser(profile: profile, blockedAt: row.createdAt)
        }
    }

    // MARK: - Relationship / discovery

    // Batched on purpose — never call per user (see get_relationships' own comment
    // in the migration: a per-row call is a guaranteed N+1).
    func fetchRelationships(userIds: [UUID]) async throws -> [UUID: Relationship] {
        guard !userIds.isEmpty else { return [:] }
        let rows: [Relationship] = try await supabase
            .rpc("get_relationships", params: ["p_user_ids": userIds.map(\.uuidString)])
            .execute()
            .value
        return Dictionary(rows.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func fetchFriendSuggestions(limit: Int = 10) async throws -> [FriendSuggestion] {
        struct Params: Encodable { let p_limit: Int }
        return try await supabase
            .rpc("get_friend_suggestions", params: Params(p_limit: limit))
            .execute()
            .value
    }

    func searchUsers(query: String) async throws -> [Profile] {
        struct SearchRow: Decodable {
            let id: UUID
            let username: String
            let displayName: String?
            let avatarUrl: String?
            let isOnline: Bool
            let lastSeenAt: Date?
            enum CodingKeys: String, CodingKey {
                case id, username
                case displayName = "display_name"
                case avatarUrl = "avatar_url"
                case isOnline = "is_online"
                case lastSeenAt = "last_seen_at"
            }
        }
        let rows: [SearchRow] = try await supabase
            .rpc("search_users", params: ["p_query": query])
            .execute()
            .value
        // search_users' row shape is narrower than the full `profiles` table (no
        // bio/created_at/etc.) — fill those with harmless placeholders since callers
        // only ever render name/username/avatar/presence from a search result.
        return rows.map { row in
            Profile(
                id: row.id, username: row.username, displayName: row.displayName,
                avatarUrl: row.avatarUrl, bio: nil, publicKey: nil,
                isOnline: row.isOnline, lastSeenAt: row.lastSeenAt,
                createdAt: Date(), updatedAt: Date(), birthdateRaw: nil
            )
        }
    }

    func fetchProfile(id: UUID) async throws -> Profile? {
        try await supabase
            .from("profiles")
            .select(Self.profileColumns)
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Message requests (conversation_members.request_state)

    // A plain self-row UPDATE, not an RPC — covered by the existing "self can
    // update own membership row" RLS policy. NEVER delete the row here: that
    // would cascade-delete the whole conversation via trg_delete_empty_conversation.
    private func setRequestState(conversationId: UUID, userId: UUID, state: String) async throws {
        struct RequestStateUpdate: Encodable { let request_state: String }
        try await supabase
            .from("conversation_members")
            .update(RequestStateUpdate(request_state: state))
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    func acceptMessageRequest(conversationId: UUID, userId: UUID) async throws {
        try await setRequestState(conversationId: conversationId, userId: userId, state: "accepted")
    }

    func declineMessageRequest(conversationId: UUID, userId: UUID) async throws {
        try await setRequestState(conversationId: conversationId, userId: userId, state: "declined")
    }
}
