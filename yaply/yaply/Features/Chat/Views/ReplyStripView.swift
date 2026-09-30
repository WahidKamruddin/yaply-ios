import SwiftUI
import Kingfisher

/// Floating card above the composer showing the message being replied to.
struct ReplyStripView: View {
    let message: DecryptedMessage
    /// True when the message being replied to is the current user's own.
    let isOwn: Bool
    let onDismiss: () -> Void

    private var targetName: String {
        isOwn ? "yourself" : (message.senderProfile?.name ?? "Deleted user")
    }

    private var thumbnailURL: URL? {
        guard !message.isDeleted, ["image", "gif", "sticker"].contains(message.type),
              let url = message.mediaUrl else { return nil }
        return URL(string: url)
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                url: message.senderProfile?.avatarUrl,
                name: message.senderProfile?.name ?? "?",
                size: 28
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.yaplyAccent)
                    (Text("Replying to ").foregroundStyle(Color.yaplySecondary)
                        + Text(targetName).fontWeight(.semibold).foregroundStyle(Color.yaplyAccent))
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(message.previewText)
                    .font(.system(size: 13))
                    .italic(message.isDeleted)
                    .foregroundStyle(message.isDeleted ? Color.yaplySecondary : Color.yaplyTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let thumbnailURL {
                KFImage(thumbnailURL)
                    .downsampling(size: CGSize(width: 132, height: 132))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.yaplyBorder, lineWidth: 1)
                    )
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(YaplyPressStyle())
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.yaplyTint)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.yaplyAccent.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.yaplyAccent.opacity(0.18), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}
