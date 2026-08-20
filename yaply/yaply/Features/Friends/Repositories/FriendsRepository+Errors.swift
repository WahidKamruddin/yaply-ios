import Foundation

// Maps the RPC error strings raised by the Friends/messaging RPCs (all
// `RAISE EXCEPTION` text, surfaced verbatim through PostgrestError.localizedDescription
// — same mechanism AccountSettingsViewModel already relies on for its 23505 check)
// to human-readable text.
func friendlyFriendsError(_ error: Error) -> String {
    let message = error.localizedDescription
    let map: [(needle: String, human: String)] = [
        ("blocked", "You can't message this user right now."),
        ("cannot send in this conversation", "You can't send messages in this conversation."),
        ("can only add friends to groups", "You can only add friends to a group."),
        ("friend request already exists", "A friend request already exists."),
        ("cannot friend yourself", "You can't add yourself as a friend."),
        ("cannot block yourself", "You can't block yourself."),
        ("cannot message yourself", "You can't message yourself."),
        ("friend request not found", "That friend request no longer exists."),
    ]
    for entry in map where message.localizedCaseInsensitiveContains(entry.needle) {
        return entry.human
    }
    return message
}
