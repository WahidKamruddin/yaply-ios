import Foundation

@Observable
@MainActor
final class ProfileCardViewModel {
    private(set) var profile: Profile?
    private(set) var relationship: Relationship?
    private(set) var isLoading = false
    var actionError: String?

    private let repository = FriendsRepository()
    private let conversationRepository = ConversationRepository()

    func load(userId: UUID, viewerId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let p = repository.fetchProfile(id: userId)
            async let rels = repository.fetchRelationships(userIds: [userId])
            let (fetchedProfile, fetchedRels) = try await (p, rels)
            profile = fetchedProfile
            relationship = fetchedRels[userId]
        } catch {
            actionError = friendlyFriendsError(error)
        }
    }

    func sendFriendRequest(viewerId: UUID) async {
        guard let profile else { return }
        do {
            try await repository.sendFriendRequest(recipientId: profile.id)
            await load(userId: profile.id, viewerId: viewerId)
        } catch {
            actionError = friendlyFriendsError(error)
        }
    }

    func acceptFriendRequest(viewerId: UUID) async {
        guard let requestId = relationship?.requestId, let profile else { return }
        do {
            try await repository.acceptFriendRequest(requestId: requestId)
            await load(userId: profile.id, viewerId: viewerId)
        } catch {
            actionError = friendlyFriendsError(error)
        }
    }

    // Covers decline (incoming), cancel (outgoing), and unfriend (accepted).
    func removeFriendship(viewerId: UUID) async {
        guard let requestId = relationship?.requestId, let profile else { return }
        do {
            try await repository.removeFriendship(friendshipId: requestId)
            await load(userId: profile.id, viewerId: viewerId)
        } catch {
            actionError = friendlyFriendsError(error)
        }
    }

    func block(viewerId: UUID) async {
        guard let profile else { return }
        do {
            try await repository.blockUser(userId: profile.id)
            await load(userId: profile.id, viewerId: viewerId)
        } catch {
            actionError = friendlyFriendsError(error)
        }
    }

    func unblock(viewerId: UUID) async {
        guard let profile else { return }
        do {
            try await repository.unblockUser(blockerId: viewerId, blockedId: profile.id)
            await load(userId: profile.id, viewerId: viewerId)
        } catch {
            actionError = friendlyFriendsError(error)
        }
    }

    // Starts (or finds) a DM with this profile and returns its conversation id.
    func startConversation(viewerId: UUID) async -> UUID? {
        guard let profile else { return nil }
        do {
            return try await conversationRepository.createDirectConversation(userId: viewerId, otherUserId: profile.id)
        } catch {
            actionError = friendlyFriendsError(error)
            return nil
        }
    }
}
