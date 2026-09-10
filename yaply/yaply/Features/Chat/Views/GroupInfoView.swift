import SwiftUI
import PostgREST
import Supabase

struct GroupInfoView: View {
    let conversationId: UUID
    let conversationName: String
    let currentUserId: UUID
    var isDirect: Bool = false
    var headerAvatarUrl: String? = nil
    let onRefresh: () async -> Void
    var onDeleted: (() -> Void)? = nil

    @State private var profileToView: MemberId? = nil

    private struct MemberId: Identifiable { let id: UUID }

    @State private var members: [MemberSummary] = []
    @State private var isLoading = false
    @State private var searchQuery = ""
    @State private var searchResults: [Profile] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var promoting: UUID? = nil
    @State private var memberToRemove: MemberSummary? = nil
    @State private var memberToPromote: MemberSummary? = nil
    @State private var showDeleteGroupConfirm = false
    @State private var isDeletingGroup = false
    @State private var isMuted = false
    @State private var muteStateLoaded = false
    @State private var isBusy = false
    @State private var showLeaveConfirm = false
    @State private var showBlockConfirm = false
    @Environment(\.dismiss) private var dismiss

    private var otherUserId: UUID? { members.first(where: { $0.userId != currentUserId })?.userId }
    private var leaveLabel: String { isDirect ? "Delete Chat" : "Leave Group" }

    private let convRepository = ConversationRepository()
    private let friendsRepository = FriendsRepository()

    private var currentMemberIsAdmin: Bool {
        members.first(where: { $0.userId == currentUserId })?.isAdmin ?? false
    }

    var body: some View {
        NavigationStack {
            List {
                // Group header
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            AvatarView(url: isDirect ? headerAvatarUrl : nil, name: conversationName, size: 64)
                            Text(conversationName)
                                .font(.title3.bold())
                                .foregroundStyle(Color.yaplyPrimary)
                            Text(isDirect ? "Direct message" : "\(members.count) member\(members.count == 1 ? "" : "s")")
                                .font(.subheadline)
                                .foregroundStyle(Color.yaplySecondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                // Member list
                Section("Members") {
                    if isLoading {
                        HStack { Spacer(); ProgressView().tint(Color.yaplyAccent); Spacer() }
                    } else {
                        ForEach(members) { member in
                            HStack(spacing: 10) {
                                ZStack(alignment: .bottomTrailing) {
                                    AvatarView(url: member.profile.avatarUrl, name: member.profile.name, size: 36)
                                    Circle()
                                        .fill(member.profile.isOnline ? Color.green : Color.yaplySecondary)
                                        .frame(width: 9, height: 9)
                                        .overlay(Circle().stroke(Color.yaplySurface, lineWidth: 1.5))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(member.profile.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color.yaplyPrimary)
                                        if member.isAdmin {
                                            Image(systemName: "crown.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Color.yellow)
                                        }
                                        if member.userId == currentUserId {
                                            Text("(you)")
                                                .font(.caption)
                                                .foregroundStyle(Color.yaplySecondary)
                                        }
                                    }
                                    Text("@\(member.profile.username)")
                                        .font(.caption)
                                        .foregroundStyle(Color.yaplySecondary)
                                }
                                Spacer()
                                if currentMemberIsAdmin && member.userId != currentUserId {
                                    HStack(spacing: 8) {
                                        if !member.isAdmin {
                                            Button {
                                                memberToPromote = member
                                            } label: {
                                                if promoting == member.userId {
                                                    ProgressView().scaleEffect(0.7)
                                                } else {
                                                    Image(systemName: "shield.fill")
                                                        .foregroundStyle(Color.yaplyAccent)
                                                        .font(.system(size: 18))
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Button {
                                            memberToRemove = member
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red)
                                                .font(.system(size: 20))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { profileToView = MemberId(id: member.userId) }
                        }
                    }
                }

                // Chat settings
                Section("Settings") {
                    Toggle(isOn: $isMuted) {
                        Label("Mute notifications", systemImage: "bell.slash")
                            .foregroundStyle(Color.yaplyPrimary)
                    }
                    .tint(Color.yaplyAccent)
                    .disabled(isBusy)
                    .onChange(of: isMuted) { _, on in
                        guard muteStateLoaded else { return }
                        Task { await setMute(on) }
                    }
                }

                Section {
                    if isDirect {
                        Button(role: .destructive) { showBlockConfirm = true } label: {
                            Label("Block User", systemImage: "hand.raised.fill")
                        }
                        .disabled(isBusy)
                    }
                    Button(role: .destructive) { showLeaveConfirm = true } label: {
                        Label(leaveLabel, systemImage: "trash")
                    }
                    .disabled(isBusy)
                } footer: {
                    Text(isDirect
                         ? "Deletes this conversation and its messages for you."
                         : "Removes you from the group. You'll lose access to its messages.")
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary)
                }

                // Delete group section (admin/owner only)
                if currentMemberIsAdmin && !isDirect {
                    Section {
                        Button(role: .destructive) {
                            showDeleteGroupConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("Delete Group for Everyone")
                                    .foregroundStyle(.red)
                            }
                        }
                        .disabled(isDeletingGroup)
                    } header: {
                        Text("Danger Zone")
                    } footer: {
                        Text("Permanently deletes the group, all messages, and all shared content for every member.")
                            .font(.caption)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }

                // Add member section (admin/owner only)
                if currentMemberIsAdmin && !isDirect {
                    Section("Add member") {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Color.yaplySecondary)
                                .font(.system(size: 13))
                            TextField("Search by username…", text: $searchQuery)
                                .font(.system(size: 14))
                                .onChange(of: searchQuery) { _, q in
                                    guard q.count >= 2 else { searchResults = []; return }
                                    Task { await searchUsers(q) }
                                }
                            if isSearching { ProgressView().scaleEffect(0.8) }
                        }

                        ForEach(searchResults) { profile in
                            Button {
                                Task { await addMember(profile.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(url: profile.avatarUrl, name: profile.name, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color.yaplyPrimary)
                                        Text("@\(profile.username)")
                                            .font(.caption)
                                            .foregroundStyle(Color.yaplySecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.yaplyAccent)
                                        .font(.system(size: 20))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(isDirect ? "Chat Settings" : "Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $profileToView) { m in
                ProfileView(userId: m.id, viewerId: currentUserId)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
            .yaplyAlert(
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
                title: "Something went wrong",
                message: error ?? ""
            )
            .yaplyConfirm(
                isPresented: Binding(get: { memberToPromote != nil }, set: { if !$0 { memberToPromote = nil } }),
                title: "Make admin?",
                message: "\(memberToPromote?.profile.name ?? "This member") will be able to add/remove members, delete any item, and delete the group.",
                icon: "star.fill",
                confirmLabel: "Make Admin",
                isDestructive: false
            ) {
                guard let m = memberToPromote else { return }
                memberToPromote = nil
                Task { await promoteToAdmin(m.userId) }
            }
            .yaplyConfirm(
                isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                title: "Remove member?",
                message: "\(memberToRemove?.profile.name ?? "This member") will lose access to this group and all its messages.",
                icon: "person.fill.xmark",
                confirmLabel: "Remove"
            ) {
                guard let m = memberToRemove else { return }
                memberToRemove = nil
                Task { await removeMember(m.userId) }
            }
            .yaplyConfirm(
                isPresented: $showDeleteGroupConfirm,
                title: "Delete group for everyone?",
                message: "This will permanently delete \"\(conversationName)\" and all its messages for every member. This cannot be undone.",
                icon: "trash.fill",
                confirmLabel: "Delete"
            ) {
                Task { await deleteGroupForEveryone() }
            }
            .yaplyConfirm(
                isPresented: $showLeaveConfirm,
                title: isDirect ? "Delete chat?" : "Leave group?",
                message: isDirect
                    ? "This conversation and its messages will be removed for you."
                    : "You'll be removed from \"\(conversationName)\" and lose access to its messages.",
                icon: "trash.fill",
                confirmLabel: isDirect ? "Delete" : "Leave"
            ) {
                Task { await leaveConversation() }
            }
            .yaplyConfirm(
                isPresented: $showBlockConfirm,
                title: "Block \(conversationName)?",
                message: "They won't be able to message you, and you won't see their messages. They won't be notified.",
                icon: "hand.raised.fill",
                confirmLabel: "Block"
            ) {
                Task { await blockOtherUser() }
            }
            .task {
                await loadMembers()
                await loadMuteState()
            }
        }
    }

    // MARK: - Helpers

    private func loadMembers() async {
        isLoading = true
        defer { isLoading = false }
        struct MemberRow: Decodable {
            let userId: UUID
            let role: String
            let profiles: Profile?
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"; case role; case profiles
            }
        }
        guard let rows: [MemberRow] = try? await supabase
            .from("conversation_members")
            .select("user_id, role, profiles(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at)")
            .eq("conversation_id", value: conversationId.uuidString)
            .execute()
            .value
        else { return }

        members = rows.compactMap { cm in
            guard let profile = cm.profiles else { return nil }
            return MemberSummary(
                userId: cm.userId,
                profile: profile,
                isAdmin: cm.role == "owner" || cm.role == "admin",
                isMuted: false,
                lastReadAt: nil
            )
        }
    }

    private func searchUsers(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        let existingIds = Set(members.map(\.userId))
        guard let results = try? await friendsRepository.searchUsers(query: query) else { return }
        searchResults = results.filter { !existingIds.contains($0.id) }
    }

    private func addMember(_ userId: UUID) async {
        do {
            try await convRepository.addGroupMember(conversationId: conversationId, userId: userId)
            searchQuery = ""
            searchResults = []
            await loadMembers()
            await onRefresh()
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    private func removeMember(_ userId: UUID) async {
        do {
            try await convRepository.removeGroupMember(conversationId: conversationId, userId: userId)
            members.removeAll { $0.userId == userId }
            await onRefresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func promoteToAdmin(_ userId: UUID) async {
        promoting = userId
        defer { promoting = nil }
        do {
            try await convRepository.promoteMemberToAdmin(conversationId: conversationId, targetUserId: userId)
            await loadMembers()
            await onRefresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteGroupForEveryone() async {
        isDeletingGroup = true
        do {
            try await convRepository.deleteGroupForEveryone(conversationId: conversationId)
            dismiss()
            onDeleted?()
        } catch {
            isDeletingGroup = false
            self.error = error.localizedDescription
        }
    }

    // MARK: - Chat settings

    /// Muted-forever sentinel — matches the web's 8_640_000_000_000 ms epoch.
    private static let muteForever = Date(timeIntervalSince1970: 8_640_000_000)

    private func loadMuteState() async {
        struct MuteRow: Decodable {
            let mutedUntil: Date?
            enum CodingKeys: String, CodingKey { case mutedUntil = "muted_until" }
        }
        guard let row: MuteRow = try? await supabase
            .from("conversation_members")
            .select("muted_until")
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: currentUserId.uuidString)
            .single()
            .execute()
            .value
        else { muteStateLoaded = true; return }
        if let until = row.mutedUntil {
            isMuted = until > Date()
        }
        muteStateLoaded = true
    }

    private func setMute(_ on: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await convRepository.muteConversation(
                conversationId: conversationId,
                userId: currentUserId,
                until: on ? Self.muteForever : nil
            )
            await onRefresh()
        } catch {
            isMuted = !on
            self.error = error.localizedDescription
        }
    }

    private func leaveConversation() async {
        isBusy = true
        do {
            try await convRepository.deleteConversation(conversationId: conversationId, userId: currentUserId)
            dismiss()
            onDeleted?()
        } catch {
            isBusy = false
            self.error = error.localizedDescription
        }
    }

    private func blockOtherUser() async {
        guard let otherUserId else { return }
        isBusy = true
        do {
            try await friendsRepository.blockUser(userId: otherUserId)
            dismiss()
            onDeleted?()
        } catch {
            isBusy = false
            self.error = friendlyFriendsError(error)
        }
    }
}
