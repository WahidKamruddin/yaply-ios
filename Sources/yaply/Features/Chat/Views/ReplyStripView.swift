import SwiftUI

struct ReplyStripView: View {
    let message: DecryptedMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.yaplyAccent)
                .frame(width: 3)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(message.senderProfile?.name ?? "Message")
                    .font(.caption)
                    .fontWeight(.semibold)
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
        .padding(.vertical, 8)
        .background(Color.yaplyBackground)
        .overlay(
            Rectangle()
                .fill(Color.yaplyBorder)
                .frame(height: 1),
            alignment: .top
        )
    }
}
