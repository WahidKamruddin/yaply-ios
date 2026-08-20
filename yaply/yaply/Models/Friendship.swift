import Foundation

// Mirrors the `friendships` table (migration 00033_friends_system.sql).
// No 'declined' status exists — decline/cancel/unfriend are all a DELETE of
// this row. There is no INSERT/UPDATE RLS policy; all writes go through
// send_friend_request / accept_friend_request / block_user.
struct Friendship: Codable, Identifiable, Hashable {
    let id: UUID
    let requesterId: UUID
    let recipientId: UUID
    var status: String // "pending" | "accepted"
    let createdAt: Date
    var updatedAt: Date
    var requesterProfile: Profile?
    var recipientProfile: Profile?

    enum CodingKeys: String, CodingKey {
        case id, status
        case requesterId = "requester_id"
        case recipientId = "recipient_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case requesterProfile = "requester"
        case recipientProfile = "recipient"
    }
}

// Matches get_relationships' returned `status` text exactly.
enum RelationshipStatus: String, Codable {
    case none
    case pendingOut = "pending_out"
    case pendingIn = "pending_in"
    case friends
    case blocked
    case blockedBy = "blocked_by"
}

// Decodes one row of get_relationships(uuid[]) — always call batched.
struct Relationship: Decodable {
    let userId: UUID
    let status: RelationshipStatus
    let requestId: UUID?
    let mutualFriends: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
        case requestId = "request_id"
        case mutualFriends = "mutual_friends"
    }
}

// Decodes one row of get_friend_suggestions(limit) — the RPC's row shape is
// narrower than the full `profiles` table (no bio/created_at/etc.), so it's
// kept as its own flat struct rather than shoehorned into Profile.
struct FriendSuggestion: Decodable, Identifiable {
    let id: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let isOnline: Bool
    let mutualFriends: Int
    let sharedGroups: Int

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case isOnline = "is_online"
        case mutualFriends = "mutual_friends"
        case sharedGroups = "shared_groups"
    }

    var name: String { displayName ?? username }
}

// View-layer wrappers built client-side from `Friendship` rows in
// FriendsRepository — mirrors the web app's Friend/FriendRequest/BlockedUser
// types (src/features/friends/api/friends.ts).
struct Friend: Identifiable, Hashable {
    var id: UUID { friendshipId }
    let friendshipId: UUID
    let profile: Profile
    let since: Date
}

struct FriendRequest: Identifiable, Hashable {
    enum Direction { case incoming, outgoing }

    let id: UUID // friendship id
    let profile: Profile
    let direction: Direction
    let createdAt: Date
}

struct BlockedUser: Identifiable, Hashable {
    var id: UUID { profile.id }
    let profile: Profile
    let blockedAt: Date
}
