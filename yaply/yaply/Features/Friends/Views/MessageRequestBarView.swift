import SwiftUI

// Replaces MessageInputView in ChatView while the caller's own
// conversation_members.request_state == "pending" — a DM from a non-friend.
// Accept/Decline/Block. Never deletes the membership row (see FriendsRepository).
struct MessageRequestBarView: View {
    let conversationId: UUID
    let currentUserId: UUID
    let otherUserId: UUID?
    let onAccepted: () -> Void
    let onDeclinedOrBlocked: () -> Void

    @State private var isProcessing = false
    @State private var error: String?
    private let repository = FriendsRepository()

    var body: some View {
        VStack(spacing: 8) {
            Text("This is a message request. Accepting lets you reply.")
                .font(.caption)
                .foregroundStyle(Color.yaplySecondary)

            HStack(spacing: 10) {
                Button(action: { Task { await accept() } }) {
                    Text("Accept")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.yaplyAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button(action: { Task { await decline() } }) {
                    Text("Decline")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.yaplyAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.yaplyAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button(action: { Task { await block() } }) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.yaplyDanger)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .disabled(isProcessing)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.yaplyDanger)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.yaplySurface)
        .overlay(Rectangle().fill(Color.yaplyBorder).frame(height: 1), alignment: .top)
    }

    private func accept() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await repository.acceptMessageRequest(conversationId: conversationId, userId: currentUserId)
            onAccepted()
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    private func decline() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await repository.declineMessageRequest(conversationId: conversationId, userId: currentUserId)
            onDeclinedOrBlocked()
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }

    private func block() async {
        guard let otherUserId else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await repository.blockUser(userId: otherUserId)
            onDeclinedOrBlocked()
        } catch {
            self.error = friendlyFriendsError(error)
        }
    }
}
