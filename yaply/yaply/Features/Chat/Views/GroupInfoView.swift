import SwiftUI
import PostgREST
import Supabase

struct GroupInfoView: View {
    let conversationId: UUID
    let conversationName: String
    let currentUserId: UUID
    let onRefresh: () async -> Void

    @State private var members: [MemberSummary] = []
    @State private var isLoading = false
    @State private var searchQuery = ""
    @State private var searchResults: [Profile] = []
    @State private var isSearching = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private let convRepository = ConversationRepository()

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
                            AvatarView(url: nil, name: conversationName, size: 64)
                            Text(conversationName)
                                .font(.title3.bold())
                                .foregroundStyle(Color.yaplyPrimary)
                            Text("\(members.count) member\(members.count == 1 ? "" : "s")")
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
                                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
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
                                    Button(role: .destructive) {
                                        Task { await removeMember(member.userId) }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                            .font(.system(size: 20))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // Add member section (admin/owner only)
                if currentMemberIsAdmin {
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
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .task { await loadMembers() }
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
        guard let results = try? await convRepository.searchUsers(query: query, excluding: currentUserId) else { return }
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
            self.error = error.localizedDescription
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
}
