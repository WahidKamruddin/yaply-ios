import SwiftUI

struct NewConversationView: View {
    let currentUserId: UUID
    let onConversationCreated: (UUID) -> Void

    @State private var searchQuery = ""
    @State private var results: [Profile] = []
    @State private var isSearching = false
    @State private var error: String?
    @Environment(AppRouter.self) private var router

    private let repo = ConversationRepository()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()

                VStack(spacing: 0) {
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
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
                    .padding(16)

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }

                    if isSearching {
                        ProgressView().padding(.top, 24)
                    } else {
                        List(results) { profile in
                            Button(action: { Task { await startChat(with: profile) } }) {
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
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(Color.yaplySecondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowBackground(Color.white)
                        }
                        .listStyle(.plain)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                    }

                    Spacer()
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
        }
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

    private func startChat(with profile: Profile) async {
        do {
            let convId = try await repo.createDirectConversation(userId: currentUserId, otherUserId: profile.id)
            onConversationCreated(convId)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
