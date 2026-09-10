import SwiftUI

// Dedicated page listing every pending message request (DMs from non-friends,
// i.e. the caller's own conversation_members.request_state == "pending").
// Requests are never shown inline in the conversation list — only summarised
// there by a single row that pushes this view.
struct MessageRequestsView: View {
    let currentUserId: UUID

    @State private var requests: [ConversationListItem] = []
    @State private var isLoading = true
    @State private var processingId: UUID?
    @State private var error: String?

    @Environment(AppRouter.self) private var router
    private let convRepository = ConversationRepository()
    private let friendsRepository = FriendsRepository()

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if requests.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.yaplySecondary)
                    Text("No message requests")
                        .font(.subheadline)
                        .foregroundStyle(Color.yaplySecondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(requests) { item in
                            requestRow(item)
                            Divider()
                                .padding(.leading, 76)
                                .foregroundStyle(Color.yaplyBorder)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .navigationTitle("Message Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func requestRow(_ item: ConversationListItem) -> some View {
        VStack(spacing: 8) {
            Button(action: { router.push(.conversation(id: item.id)) }) {
                ConversationRowView(item: item, currentUserId: currentUserId)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button(action: { Task { await accept(item) } }) {
                    Text("Accept")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.yaplyAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                Button(action: { Task { await decline(item) } }) {
                    Text("Decline")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.yaplyAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.yaplyAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            .disabled(processingId == item.id)
            .padding(.horizontal, 16)

            if let error, processingId == nil {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.yaplyDanger)
            }
        }
        .padding(.bottom, 10)
    }

    private func load() async {
        do {
            let all = try await convRepository.fetchConversations(userId: currentUserId)
            requests = all.filter(\.isMessageRequest)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func accept(_ item: ConversationListItem) async {
        processingId = item.id
        defer { processingId = nil }
        do {
            try await friendsRepository.acceptMessageRequest(conversationId: item.id, userId: currentUserId)
            requests.removeAll { $0.id == item.id }
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    private func decline(_ item: ConversationListItem) async {
        processingId = item.id
        defer { processingId = nil }
        do {
            try await friendsRepository.declineMessageRequest(conversationId: item.id, userId: currentUserId)
            requests.removeAll { $0.id == item.id }
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }
}
