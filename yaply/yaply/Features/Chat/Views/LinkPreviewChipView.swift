import SwiftUI
import Kingfisher

// Shown above the composer while a link preview resolves / after it resolves,
// dismissible; re-appears if the URL in the text changes. Mirrors the web
// composer's chip (MessageInput.tsx). See ../CLAUDE.md's "Link previews" section.
struct LinkPreviewChipView: View {
    let preview: LinkPreview?
    let isLoading: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let imageUrlString = preview?.imageUrl, let imageUrl = URL(string: imageUrlString) {
                KFImage(imageUrl)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(isLoading && preview == nil ? "Fetching preview…" : (preview?.title ?? preview?.url ?? ""))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.yaplyAccent)
                    .lineLimit(1)
                if let siteName = preview?.siteName {
                    Text(siteName)
                        .font(.caption2)
                        .foregroundStyle(Color.yaplyTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
            }
            .accessibilityLabel("Remove link preview")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
