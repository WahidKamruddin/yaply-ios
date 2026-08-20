import Supabase
import Foundation

@Observable
@MainActor
final class FriendsViewModel {
    private(set) var friends: [Friend] = []
    private(set) var incomingRequests: [FriendRequest] = []
    private(set) var outgoingRequests: [FriendRequest] = []
    private(set) var suggestions: [FriendSuggestion] = []
    private(set) var blockedUsers: [BlockedUser] = []
    private(set) var isLoading = false
    var error: String?

    // Discover tab
    var searchQuery = ""
    private(set) var isSearching = false
    private(set) var searchResults: [Profile] = []
    private(set) var relationshipsByUserId: [UUID: RelationshipStatus] = [:]

    private let repository = FriendsRepository()
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?

    func loadAll(userId: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let f = repository.fetchFriends(userId: userId)
            async let reqs = repository.fetchFriendRequests(userId: userId)
            async let sugg = repository.fetchFriendSuggestions()
            async let blocked = repository.fetchBlockedUsers(userId: userId)
            let (fetchedFriends, fetchedReqs, fetchedSugg, fetchedBlocked) = try await (f, reqs, sugg, blocked)
            friends = fetchedFriends
            incomingRequests = fetchedReqs.incoming
            outgoingRequests = fetchedReqs.outgoing
            suggestions = fetchedSugg
            blockedUsers = fetchedBlocked
            await refreshRelationships(for: fetchedSugg.map(\.id), me: userId)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    // Debounced search — call from the view via .task(id: vm.searchQuery).
    func search(userId: UUID) async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, searchQuery.trimmingCharacters(in: .whitespaces) == query else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await repository.searchUsers(query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            await refreshRelationships(for: results.map(\.id), me: userId)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    func sendRequest(to userId: UUID, me: UUID) async {
        do {
            try await repository.sendFriendRequest(recipientId: userId)
            await refreshRelationships(for: [userId], me: me)
            await loadAll(userId: me)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    func acceptRequest(_ request: FriendRequest, me: UUID) async {
        do {
            try await repository.acceptFriendRequest(requestId: request.id)
            await loadAll(userId: me)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    // Covers decline (incoming), cancel (outgoing), and unfriend (accepted) —
    // all three are the same underlying DELETE.
    func removeFriendship(_ friendshipId: UUID, me: UUID) async {
        do {
            try await repository.removeFriendship(friendshipId: friendshipId)
            await loadAll(userId: me)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    func block(_ userId: UUID, me: UUID) async {
        do {
            try await repository.blockUser(userId: userId)
            await loadAll(userId: me)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    func unblock(_ blockerId: UUID, _ blockedId: UUID) async {
        do {
            try await repository.unblockUser(blockerId: blockerId, blockedId: blockedId)
            await loadAll(userId: blockerId)
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    private func refreshRelationships(for ids: [UUID], me: UUID) async {
        guard !ids.isEmpty else { return }
        if let rels = try? await repository.fetchRelationships(userIds: ids) {
            for (id, rel) in rels { relationshipsByUserId[id] = rel.status }
        }
    }

    // MARK: - Realtime

    // Treats every friendships event purely as an invalidation trigger and
    // re-fetches, matching ChatViewModel.startRealtime's house style — never
    // parses the payload into domain state.
    func startRealtime(userId: UUID) {
        realtimeTask?.cancel()
        if let ch = realtimeChannel {
            Task { await supabase.removeChannel(ch) }
            realtimeChannel = nil
        }
        realtimeTask = Task {
            let channel = supabase.channel("friends-\(userId.uuidString)-\(UUID().uuidString)")
            realtimeChannel = channel
            let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "friendships")
            let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: "friendships")
            let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "friendships")
            try? await channel.subscribeWithError()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in inserts { await self.loadAll(userId: userId) } }
                group.addTask { for await _ in updates { await self.loadAll(userId: userId) } }
                group.addTask { for await _ in deletes { await self.loadAll(userId: userId) } }
            }
        }
    }

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        if let ch = realtimeChannel {
            Task { await supabase.removeChannel(ch) }
            realtimeChannel = nil
        }
    }
}
