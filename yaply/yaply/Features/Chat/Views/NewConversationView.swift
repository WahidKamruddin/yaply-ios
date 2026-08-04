import SwiftUI

struct NewConversationView: View {
    let currentUserId: UUID
    let onConversationCreated: (UUID) -> Void

    @State private var searchQuery = ""
    @State private var results: [Profile] = []
    @State private var selected: [Profile] = []
    @State private var groupName = ""
    @State private var isSearching = false
    @State private var isCreating = false
    @State private var error: String?
    @Environment(AppRouter.self) private var router

    private let repo = ConversationRepository()

    private var isGroup: Bool { selected.count > 1 }
    private var canCreate: Bool { !selected.isEmpty && !isCreating }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Selected chips
                    if !selected.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selected) { profile in
                                    HStack(spacing: 4) {
                                        Text(profile.name)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.yaplyAccent)
                                        Button(action: { deselect(profile) }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Color.yaplyAccent)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.yaplyAccent.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .background(Color.yaplySurface)
                    }

                    // Group name field (shown when 2+ selected)
                    if isGroup {
                        HStack {
                            Image(systemName: "person.3")
                                .foregroundStyle(Color.yaplySecondary)
                            TextField("Group name (optional)", text: $groupName)
                                .autocorrectionDisabled()
                        }
                        .padding(12)
                        .background(Color.yaplySurface)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.yaplyBorder), alignment: .bottom)
                    }

                    // Error
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.yaplySecondary)
                        TextField("Search by username...", text: $searchQuery)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: searchQuery) { _, new in
                                Task { await search(new) }
                            }
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = ""; results = [] }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.yaplySecondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.yaplySurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
                    .padding(16)

                    if isSearching {
                        ProgressView().padding(.top, 24)
                    } else {
                        List(results) { profile in
                            Button(action: { toggle(profile) }) {
                                HStack(spacing: 12) {
                                    AvatarView(url: profile.avatarUrl, name: profile.name, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color.yaplyPrimary)
                                        Text("@\(profile.username)")
                                            .font(.caption)
                                            .foregroundStyle(Color.yaplySecondary)
                                    }
                                    Spacer()
                                    if isSelected(profile) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.yaplyAccent)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(Color.yaplySecondary.opacity(0.4))
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowBackground(Color.yaplySurface)
                        }
                        .listStyle(.plain)
                        .background(Color.yaplySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                    }

                    Spacer()
                }
            }
            .navigationTitle(isGroup ? "New Group" : "New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isCreating {
                        ProgressView()
                    } else if canCreate {
                        Button(isGroup ? "Create" : "Start") {
                            Task { await create() }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.yaplyAccent)
                    }
                }
            }
        }
    }

    private func isSelected(_ profile: Profile) -> Bool {
        selected.contains { $0.id == profile.id }
    }

    private func toggle(_ profile: Profile) {
        if isSelected(profile) {
            deselect(profile)
        } else {
            selected.append(profile)
        }
    }

    private func deselect(_ profile: Profile) {
        selected.removeAll { $0.id == profile.id }
    }

    private func search(_ query: String) async {
        guard query.count >= 2 else { results = []; return }
        isSearching = true
        do {
            results = try await repo.searchUsers(query: query, excluding: currentUserId)
        } catch {
            self.error = error.localizedDescription
        }
        isSearching = false
    }

    private func create() async {
        guard !selected.isEmpty else { return }
        isCreating = true
        error = nil
        do {
            let convId: UUID
            if selected.count == 1 {
                convId = try await repo.createDirectConversation(userId: currentUserId, otherUserId: selected[0].id)
            } else {
                convId = try await repo.createGroupConversation(
                    userId: currentUserId,
                    memberIds: selected.map { $0.id },
                    name: groupName
                )
            }
            onConversationCreated(convId)
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}
