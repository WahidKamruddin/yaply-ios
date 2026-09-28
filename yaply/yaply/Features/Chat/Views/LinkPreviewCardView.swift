import SwiftUI
import Kingfisher

// The whole card opens the URL, exactly like FileAttachmentBubble. Mirrors the
// web bubble's LinkPreviewCard. See ../CLAUDE.md's "Link previews" section.
struct LinkPreviewCardView: View {
    let preview: LinkPreview
    let isOwn: Bool
    // True when the bubble also has message text above this card, so the
    // card gets a top spacer instead of acting as the whole bubble's content.
    let hasText: Bool
    @Environment(\.openURL) private var openURL

    private var hostname: String {
        guard let url = URL(string: preview.url), let host = url.host else { return preview.url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        Button {
            guard let url = URL(string: preview.url) else { return }
            openURL(url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imageUrlString = preview.imageUrl, let imageUrl = URL(string: imageUrlString) {
                    KFImage(imageUrl)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = preview.title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isOwn ? .white : Color.yaplyPrimary)
                            .lineLimit(2)
                    }
                    if let description = preview.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(isOwn ? Color.white.opacity(0.8) : Color.yaplySecondary)
                            .lineLimit(2)
                    }
                    Text(preview.siteName ?? hostname)
                        .font(.system(size: 10))
                        .foregroundStyle(isOwn ? Color.white.opacity(0.6) : Color.yaplyTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 240)
        .background(isOwn ? Color.white.opacity(0.1) : Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isOwn ? Color.white.opacity(0.25) : Color.yaplyBorderSoft, lineWidth: 1)
        )
        .padding(.top, hasText ? 6 : 0)
    }
}
