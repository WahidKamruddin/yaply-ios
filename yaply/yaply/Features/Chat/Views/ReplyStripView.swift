import SwiftUI

struct ReplyStripView: View {
    let message: DecryptedMessage
    let onDismiss: () -> Void

    // Plain text, no highlight/accent bar. Top padding gives it breathing
    // room from the message list above (it has no background/divider of its
    // own to create that separation).
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(message.senderProfile?.name ?? "message")")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.yaplyAccent)
                Text(message.isDeleted ? "Message deleted" : message.content)
                    .font(.caption)
                    .foregroundStyle(Color.yaplyTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}
