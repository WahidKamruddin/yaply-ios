import SwiftUI

private enum FriendsTab: String, CaseIterable {
    case friends = "Friends"
    case requests = "Requests"
    case sent = "Sent"
    case discover = "Discover"
    case blocked = "Blocked"
}

struct FriendsView: View {
    let currentUserId: UUID

    @State private var vm = FriendsViewModel()
    @State private var tab: FriendsTab = .friends
    @State private var selectedProfileId: UUID?
    @State private var friendshipToRemove: Friend?
    @State private var friendToBlock: Friend?

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                tabPicker

                if vm.isLoading && vm.friends.isEmpty && vm.incomingRequests.isEmpty {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            switch tab {
                            case .friends: friendsList
                            case .requests: requestsList
                            case .sent: sentList
                            case .discover: discoverContent
                            case .blocked: blockedList
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.loadAll(userId: currentUserId)
            vm.startRealtime(userId: currentUserId)
        }
        .onDisappear { vm.stopRealtime() }
        .sheet(item: Binding(
            get: { selectedProfileId.map { IdentifiableUUID(id: $0) } },
            set: { selectedProfileId = $0?.id }
        )) { wrapped in
            ProfileView(userId: wrapped.id, viewerId: currentUserId)
        }
        .alert("Remove Friend", isPresented: Binding(
            get: { friendshipToRemove != nil },
            set: { if !$0 { friendshipToRemove = nil } }
        ), presenting: friendshipToRemove) { friend in
            Button("Remove", role: .destructive) {
                Task { await vm.removeFriendship(friend.friendshipId, me: currentUserId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { friend in
            Text("Remove \(friend.profile.name) from your friends?")
        }
        .alert("Block User", isPresented: Binding(
            get: { friendToBlock != nil },
            set: { if !$0 { friendToBlock = nil } }
        ), presenting: friendToBlock) { friend in
            Button("Block", role: .destructive) {
                Task { await vm.block(friend.profile.id, me: currentUserId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { friend in
            Text("\(friend.profile.name) won't be able to message you or see your profile.")
        }
        .alert("Error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK", role: .cancel) { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FriendsTab.allCases, id: \.self) { t in
                    let count = badgeCount(for: t)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                    } label: {
                        HStack(spacing: 5) {
                            Text(t.rawValue)
                                .font(.system(size: 13, weight: tab == t ? .semibold : .medium))
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Color.yaplyAccent)
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(tab == t ? .white : Color.yaplyPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(tab == t ? Color.yaplyAccent : Color.yaplyTint)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func badgeCount(for t: FriendsTab) -> Int {
        switch t {
        case .requests: return vm.incomingRequests.count
        default: return 0
        }
    }

    // MARK: - Friends

    private var friendsList: some View {
        Group {
            if vm.friends.isEmpty {
                emptyState(icon: "person.2", text: "No friends yet")
            } else {
                ForEach(vm.friends) { friend in
                    UserRowView(
                        name: friend.profile.name,
                        username: friend.profile.username,
                        avatarUrl: friend.profile.avatarUrl,
                        isOnline: friend.profile.isOnline,
                        onTap: { selectedProfileId = friend.profile.id }
                    )
                    .contextMenu {
                        Button(role: .destructive) { friendshipToRemove = friend } label: {
                            Label("Remove Friend", systemImage: "person.badge.minus")
                        }
                        Button(role: .destructive) { friendToBlock = friend } label: {
                            Label("Block", systemImage: "hand.raised")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Requests (incoming)

    private var requestsList: some View {
        Group {
            if vm.incomingRequests.isEmpty {
                emptyState(icon: "person.crop.circle.badge.questionmark", text: "No pending requests")
            } else {
                ForEach(vm.incomingRequests) { request in
                    UserRowView(
                        name: request.profile.name,
                        username: request.profile.username,
                        avatarUrl: request.profile.avatarUrl,
                        isOnline: request.profile.isOnline,
                        onTap: { selectedProfileId = request.profile.id }
                    ) {
                        HStack(spacing: 6) {
                            FriendActionButton(title: "Accept", style: .primary) {
                                Task { await vm.acceptRequest(request, me: currentUserId) }
                            }
                            FriendActionButton(title: "Decline", style: .secondary) {
                                Task { await vm.removeFriendship(request.id, me: currentUserId) }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sent (outgoing)

    private var sentList: some View {
        Group {
            if vm.outgoingRequests.isEmpty {
                emptyState(icon: "paperplane", text: "No sent requests")
            } else {
                ForEach(vm.outgoingRequests) { request in
                    UserRowView(
                        name: request.profile.name,
                        username: request.profile.username,
                        avatarUrl: request.profile.avatarUrl,
                        isOnline: request.profile.isOnline,
                        subtitle: "Requested",
                        onTap: { selectedProfileId = request.profile.id }
                    ) {
                        FriendActionButton(title: "Cancel", style: .secondary) {
                            Task { await vm.removeFriendship(request.id, me: currentUserId) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Discover

    private var discoverContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.yaplySecondary)
                    .font(.system(size: 14))
                TextField("Search by username or name...", text: $vm.searchQuery)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(10)
            .background(Color.yaplyTint)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .task(id: vm.searchQuery) {
                await vm.search(userId: currentUserId)
            }

            if vm.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                if vm.isSearching {
                    ProgressView().padding(.top, 24)
                } else if vm.searchResults.isEmpty {
                    emptyState(icon: "person.crop.circle.badge.questionmark", text: "No results")
                } else {
                    ForEach(vm.searchResults) { profile in
                        discoverRow(profile)
                    }
                }
            } else if vm.suggestions.isEmpty {
                emptyState(icon: "sparkles", text: "No suggestions yet")
            } else {
                ForEach(vm.suggestions) { suggestion in
                    UserRowView(
                        name: suggestion.name,
                        username: suggestion.username,
                        avatarUrl: suggestion.avatarUrl,
                        isOnline: suggestion.isOnline,
                        subtitle: suggestion.mutualFriends > 0 ? "\(suggestion.mutualFriends) mutual friends" : nil,
                        onTap: { selectedProfileId = suggestion.id }
                    ) {
                        discoverActionButton(for: suggestion.id)
                    }
                }
            }
        }
    }

    private func discoverRow(_ profile: Profile) -> some View {
        UserRowView(
            name: profile.name,
            username: profile.username,
            avatarUrl: profile.avatarUrl,
            isOnline: profile.isOnline,
            onTap: { selectedProfileId = profile.id }
        ) {
            discoverActionButton(for: profile.id)
        }
    }

    // `blockedBy` renders identically to `none` — never reveal a block to the
    // blocked party.
    @ViewBuilder
    private func discoverActionButton(for userId: UUID) -> some View {
        switch vm.relationshipsByUserId[userId] ?? .none {
        case .none, .blockedBy:
            FriendActionButton(title: "Add", style: .primary) {
                Task { await vm.sendRequest(to: userId, me: currentUserId) }
            }
        case .pendingOut:
            FriendActionButton(title: "Requested", style: .disabled) {}
        case .pendingIn:
            FriendActionButton(title: "Respond", style: .secondary) {
                selectedProfileId = userId
            }
        case .friends:
            FriendActionButton(title: "Friends", style: .disabled) {}
        case .blocked:
            FriendActionButton(title: "Blocked", style: .disabled) {}
        }
    }

    // MARK: - Blocked

    private var blockedList: some View {
        Group {
            if vm.blockedUsers.isEmpty {
                emptyState(icon: "hand.raised", text: "No blocked users")
            } else {
                ForEach(vm.blockedUsers) { blocked in
                    UserRowView(
                        name: blocked.profile.name,
                        username: blocked.profile.username,
                        avatarUrl: blocked.profile.avatarUrl,
                        isOnline: false,
                        onTap: {}
                    ) {
                        FriendActionButton(title: "Unblock", style: .secondary) {
                            Task { await vm.unblock(currentUserId, blocked.profile.id) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(Color.yaplySecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.yaplySecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}
