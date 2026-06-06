import Foundation

struct InAppNotification: Identifiable {
    let id: UUID
    let conversationId: UUID
    let conversationName: String
    let senderName: String
}

@Observable
final class NotificationManager {
    var current: InAppNotification?
    private var dismissTask: Task<Void, Never>?

    func show(conversationId: UUID, conversationName: String, senderName: String) {
        let notification = InAppNotification(
            id: UUID(),
            conversationId: conversationId,
            conversationName: conversationName,
            senderName: senderName
        )
        current = notification
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
