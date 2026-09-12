import SwiftUI
import Kingfisher
import UIKit // NSString.boundingRect for reply-quote width estimation

// Tab names that match ConversationDetailView tab IDs
private let systemMessageTabMap: [(pattern: String, tab: String)] = [
    ("Plan created",  "events"),
    ("Event created", "events"),
    ("Album created", "albums"),
    ("Task created",  "tasks"),
    ("Note created",  "notes"),
    ("Budget created","budgets"),
    ("Reminder set",  "reminders"),
]

private func systemMessageTab(for content: String) -> String? {
    systemMessageTabMap.first { content.localizedCaseInsensitiveContains($0.pattern) }?.tab
}

struct MessageBubbleView: View {
    let message: DecryptedMessage
    let isOwn: Bool
    let currentUserId: UUID
    var replyMessage: DecryptedMessage?
    var threadCount: Int = 0
    var isRead: Bool? = nil
    let reactions: [ReactionGroup]
    let onReply: (DecryptedMessage) -> Void
    let onDelete: (UUID) -> Void
    var onReact: ((UUID, String) -> Void)?
    var onOpenThread: ((DecryptedMessage) -> Void)?
    var onReplyInThread: ((DecryptedMessage) -> Void)?
    var onQuotationClick: ((UUID) -> Void)?
    var onOpenDetail: ((String) -> Void)?
    /// Long-press on the bubble — opens the Messenger-style actions overlay.
    var onLongPress: ((DecryptedMessage) -> Void)?

    var swipeOffset: CGFloat = 0

    @State private var replyDragOffset: CGFloat = 0
    @State private var hasTriggeredReply = false
    // Actual rendered height of the underlap quote bubble, measured via
    // ReplyQuoteHeightKey so the main bubble's half-height offset is exact
    // regardless of font metrics or Dynamic Type — 64 is a sane fallback
    // (8pt top pad + ~16pt line + 40pt bottom pad, matching web's spec)
    // before the first layout pass reports the real value.
    @State private var replyQuoteHeight: CGFloat = 64
    // Width actually available to this row's bubble column, measured via
    // ReplyAvailableWidthKey — used to estimate how wide the *original*
    // (replied-to) message's own bubble rendered at. 220 is a sane fallback
    // before the first layout pass reports the real value.
    @State private var replyAvailableWidth: CGFloat = 220

    var body: some View {
        Group {
            if message.type == "system" {
                systemMessageView
            } else {
                ZStack(alignment: .trailing) {
                    Text(message.createdAt.timeOnly)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.yaplySecondary)
                        .padding(.trailing, 16)
                        .opacity(Double(min(1, abs(swipeOffset) / 50)))

                    mainRow
                        .offset(x: swipeOffset)
                }
            }
        }
    }

    // System messages: centered pill. Expired ones (deletedAt in the past) are hidden.
    @ViewBuilder
    private var systemMessageView: some View {
        if let expiry = message.deletedAt, expiry <= Date() {
            EmptyView()
        } else {
            let tab = systemMessageTab(for: message.content)
            HStack(spacing: 4) {
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.yaplySecondary)
                if let tab, let onOpenDetail {
                    Button {
                        onOpenDetail(tab)
                    } label: {
                        Text("Open →")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.yaplyAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.yaplyTint)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.yaplyBorderSoft, lineWidth: 0.5))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var mainRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwn { Spacer(minLength: 60) }

            if !isOwn {
                AvatarView(
                    url: message.senderProfile?.avatarUrl,
                    name: message.senderProfile?.name ?? "?",
                    size: 28
                )
            }

            // ZStack lets the reply icon sit behind the bubble column.
            // As the VStack shifts right, the icon is revealed at the leading edge.
            ZStack(alignment: .leading) {
                if !isOwn {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.yaplyAccent)
                        .opacity(Double(min(1, replyDragOffset / 50)))
                        .scaleEffect(min(1.0, max(0.4, replyDragOffset / 50)))
                }

                VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                    if !isOwn, let profile = message.senderProfile {
                        Text(profile.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.yaplyTertiary)
                            .padding(.leading, 4)
                    }

                    if let reply = replyMessage {
                        replyLabelView(reply)

                        if replyCanUnderlap(reply) {
                            ZStack(alignment: isOwn ? .topTrailing : .topLeading) {
                                replyQuoteUnderlap(reply)
                                decoratedBubbleContent.padding(.top, replyQuoteHeight / 2)
                            }
                            .onPreferenceChange(ReplyQuoteHeightKey.self) { replyQuoteHeight = $0 }
                        } else {
                            replyQuotePill(reply)
                            decoratedBubbleContent
                        }
                    } else {
                        decoratedBubbleContent
                    }

                    if !reactions.isEmpty {
                        reactionPills
                    }

                    if threadCount > 0 {
                        Button {
                            onOpenThread?(message)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 10))
                                Text("\(threadCount) \(threadCount == 1 ? "reply" : "replies") · Open thread")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Color.yaplyAccent)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    }

                    // Read checkmarks only — timestamp revealed by swipe
                    if isOwn && !message.isDeleted && isRead != nil {
                        readCheckmarks
                            .padding(.horizontal, 4)
                    }
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: ReplyAvailableWidthKey.self, value: g.size.width)
                    }
                )
                .onPreferenceChange(ReplyAvailableWidthKey.self) { replyAvailableWidth = $0 }
                .offset(x: !isOwn ? replyDragOffset : 0)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard !isOwn, !message.isDeleted else { return }
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) > abs(dy), dx > 0 else { return }
                            replyDragOffset = min(60, dx)
                            if replyDragOffset >= 55 && !hasTriggeredReply {
                                hasTriggeredReply = true
                                onReply(message)
                            }
                        }
                        .onEnded { _ in
                            guard !isOwn else { return }
                            hasTriggeredReply = false
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                replyDragOffset = 0
                            }
                        }
                )
            }

            if !isOwn { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Read checkmarks

    private var readCheckmarks: some View {
        Group {
            if isRead == true {
                HStack(spacing: -3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.yaplyAccent)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary.opacity(0.7))
            }
        }
    }

    // MARK: - Reaction pills

    private var reactionPills: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { group in
                Button { onReact?(message.id, group.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(group.emoji).font(.system(size: 14))
                        Text("\(group.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(group.reactedByMe ? Color.yaplyAccent : Color.yaplyPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(group.reactedByMe ? Color.yaplyAccent.opacity(0.15) : Color.yaplyCard)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(group.reactedByMe ? Color.yaplyAccent.opacity(0.4) : Color.yaplyBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bubble content

    private var bubbleContent: some View {
        BubbleContentView(message: message, isOwn: isOwn)
    }

    /// `bubbleContent` plus the anchor-tracking + long-press modifiers every
    /// reply layout (underlap or plain-pill) needs applied identically.
    private var decoratedBubbleContent: some View {
        bubbleContent
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: BubbleAnchorKey.self,
                        value: [message.id: g.frame(in: .global)]
                    )
                }
            )
            .onLongPressGesture(minimumDuration: 0.3) {
                guard !message.isDeleted else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onLongPress?(message)
            }
    }

    // MARK: - Reply label ("X replied to Y")

    /// Frameless media (GIFs/stickers) as the main bubble has no solid
    /// background to hide the quote's bottom edge behind, so it keeps the
    /// old floating-pill placement instead of underlapping.
    private func replyCanUnderlap(_ reply: DecryptedMessage) -> Bool {
        !((message.type == "sticker" || message.type == "gif") && message.mediaUrl != nil)
    }

    private func replyLabel(_ reply: DecryptedMessage) -> String {
        let subject = isOwn ? "You" : (message.senderProfile?.name ?? "Deleted user")
        let object: String
        if reply.senderId == currentUserId {
            object = isOwn ? "yourself" : "you"
        } else if !isOwn && reply.senderId == message.senderId {
            object = "themselves"
        } else {
            object = reply.senderProfile?.name ?? "Deleted user"
        }
        return "\(subject) replied to \(object)"
    }

    private func replyLabelView(_ reply: DecryptedMessage) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 9))
            Text(replyLabel(reply))
                .font(.system(size: 10))
        }
        .foregroundStyle(Color.yaplySecondary)
        .padding(.horizontal, 4)
    }

    // MARK: - Reply quote bubble

    /// Preview text for the quote, shared by both layouts. Sender name is
    /// intentionally omitted — the label above already says who replied to
    /// whom.
    private func replyPreviewText(_ reply: DecryptedMessage) -> some View {
        Text(reply.isDeleted ? "Message deleted" : replyPreview(reply))
            .font(.system(size: 12))
            .italic(reply.isDeleted)
            .foregroundStyle(reply.isDeleted ? Color.yaplySecondary : Color.yaplyTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func replyPreview(_ reply: DecryptedMessage) -> String {
        if reply.isDeleted { return "Message deleted" }
        switch reply.type {
        case "image", "sticker": return "📷 Photo"
        case "gif": return "GIF"
        case "voice": return "🎤 Voice message"
        case "file": return "📎 File"
        default:
            if reply.decryptFailed { return "🔒 Encrypted message" }
            return String(reply.content.prefix(80))
        }
    }

    /// Reproduces `BubbleContentView`'s plain-text bubble metrics (15pt
    /// system font, 14pt horizontal padding) to estimate how wide the
    /// *original* message's own bubble rendered at, so the quote can match
    /// its footprint instead of hugging the (smaller-font, truncated)
    /// preview text or the new reply's own bubble width.
    private func naturalBubbleWidth(for text: String, maxContentWidth: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 15)
        let horizontalPadding: CGFloat = 28 // matches BubbleContentView's .padding(.horizontal, 14) × 2
        let availableForText = max(0, maxContentWidth - horizontalPadding)
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: availableForText, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return min(availableForText, ceil(bounding.width)) + horizontalPadding
    }

    /// Width the quote should render at, or `nil` to just hug its own short
    /// fixed label — only original **text** messages have a meaningful "own
    /// bubble width" to match; deleted/decrypt-failed/media previews are
    /// always a short fixed string with nothing to match.
    private func replyQuoteWidth(_ reply: DecryptedMessage) -> CGFloat? {
        guard reply.type == "text", !reply.isDeleted, !reply.decryptFailed else { return nil }
        let replyIsOwn = reply.senderId == currentUserId
        // The avatar (28pt) + its 8pt spacing only reserve space on the
        // received side; correct for the original message's row having had
        // a different amount of available width than this reply's row.
        let avatarAdjustment: CGFloat = (isOwn == replyIsOwn) ? 0 : (isOwn ? -36 : 36)
        return naturalBubbleWidth(for: reply.content, maxContentWidth: replyAvailableWidth + avatarAdjustment)
    }

    /// Frameless-media case: a plain pill above the bubble, normal flow.
    private func replyQuotePill(_ reply: DecryptedMessage) -> some View {
        Button {
            onQuotationClick?(reply.id)
        } label: {
            replyPreviewText(reply)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .frame(width: replyQuoteWidth(reply), alignment: isOwn ? .trailing : .leading)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder, lineWidth: 1))
        .padding(.bottom, 4)
    }

    /// Underlap case: tall bottom padding gives the quote a fixed ~64pt
    /// height; the main bubble sits at exactly half of the quote's *measured*
    /// height (via `ReplyQuoteHeightKey`, read at the `ZStack` call site),
    /// tucking behind the quote's lower half. Width matches the original
    /// message's own bubble footprint (`replyQuoteWidth`), not a fixed cap.
    private func replyQuoteUnderlap(_ reply: DecryptedMessage) -> some View {
        Button {
            onQuotationClick?(reply.id)
        } label: {
            replyPreviewText(reply)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 40)
        }
        .buttonStyle(.plain)
        .frame(width: replyQuoteWidth(reply), alignment: isOwn ? .trailing : .leading)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder, lineWidth: 1))
        .background(
            GeometryReader { g in
                Color.clear.preference(key: ReplyQuoteHeightKey.self, value: g.size.height)
            }
        )
        .zIndex(0)
    }
}

/// Reports the available width for a row's bubble column so the reply quote
/// can estimate the original message's own bubble width (`replyQuoteWidth`).
private struct ReplyAvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 220
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Reports the underlap quote bubble's actual rendered height so the main
/// bubble's half-height offset (`MessageBubbleView`) is exact regardless of
/// font metrics or Dynamic Type, mirroring `BubbleAnchorKey`'s pattern.
private struct ReplyQuoteHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The visual body of a message bubble (text / media / sticker / gif / deleted /
/// decrypt-failed) with no row chrome. Extracted so the long-press actions
/// overlay can render an exact copy of the tapped bubble.
struct BubbleContentView: View {
    let message: DecryptedMessage
    let isOwn: Bool

    @ViewBuilder
    var body: some View {
        if message.isDeleted {
            Text("Message deleted")
                .font(.subheadline)
                .italic()
                .foregroundStyle(Color.yaplySecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.yaplyCard)
                .clipShape(BubbleShape(isOwn: isOwn))
                .overlay(BubbleShape(isOwn: isOwn).stroke(Color.yaplyBorderSoft, lineWidth: 1))
        } else if message.decryptFailed {
            // Sealed before this device existed (no matching envelope) or a bad
            // wrap/content — an honest, permanent state. Never render raw ciphertext.
            HStack(spacing: 6) {
                Image(systemName: "lock.slash")
                Text("Couldn't decrypt this message")
            }
            .font(.subheadline)
            .italic()
            .foregroundStyle(Color.yaplySecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.yaplyCard)
            .clipShape(BubbleShape(isOwn: isOwn))
            .overlay(BubbleShape(isOwn: isOwn).stroke(Color.yaplyBorderSoft, lineWidth: 1))
        } else if message.type == "sticker" {
            // Stickers float free — no bubble, no border, larger, with a little pop.
            Group {
                if let url = message.mediaUrl.flatMap(URL.init) {
                    KFAnimatedImage(url)
                        .configure { $0.contentMode = .scaleAspectFit }
                        .placeholder {
                            ProgressView().tint(Color.yaplyAccent).frame(width: 120, height: 120)
                        }
                        .fade(duration: 0.15)
                        .frame(maxWidth: 150, maxHeight: 150)
                        .shadow(color: Color.yaplyShadow, radius: 3, y: 2)
                } else {
                    // Optimistic row while the PNG uploads.
                    ProgressView().tint(Color.yaplyAccent).frame(width: 120, height: 120)
                }
            }
            .modifier(StickerPopIn())
        } else if message.type == "gif", let urlString = message.mediaUrl, let url = URL(string: urlString) {
            // No bubble — a plain rounded card that hugs the GIF, matching the web app.
            AnimatedGifView(url: url)
        } else if message.type == "voice", let url = message.mediaUrl.flatMap(URL.init) {
            VoiceMessageBubble(url: url, isOwn: isOwn)
        } else if message.type == "file", let url = message.mediaUrl.flatMap(URL.init) {
            FileAttachmentBubble(url: url, isOwn: isOwn)
        } else if message.isMedia, let urlString = message.mediaUrl, let url = URL(string: urlString) {
            // No bubble — a plain rounded card, matching the web app.
            KFImage(url)
                .placeholder {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.yaplyBackground)
                        ProgressView().tint(Color.yaplyAccent)
                    }
                    .frame(width: 200, height: 140)
                }
                .onFailureView {
                    mediaPill(systemImage: "photo", label: "Image unavailable")
                }
                .fade(duration: 0.15)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Text(message.content)
                .font(.system(size: 15))
                .foregroundStyle(isOwn ? .white : Color.yaplyPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Group {
                        if isOwn {
                            LinearGradient(
                                colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else {
                            Color.yaplyCard
                        }
                    }
                )
                .clipShape(BubbleShape(isOwn: isOwn))
                .overlay(
                    BubbleShape(isOwn: isOwn)
                        .stroke(isOwn ? Color.clear : Color.yaplyBorderSoft, lineWidth: 1)
                )
        }
    }

    private func mediaPill(systemImage: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(Color.yaplySecondary)
            Text(label).font(.caption).foregroundStyle(Color.yaplySecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.yaplyBackground)
        .clipShape(BubbleShape(isOwn: isOwn))
        .overlay(BubbleShape(isOwn: isOwn).stroke(Color.yaplyBorder, lineWidth: 1))
    }
}

// MARK: - Animated GIF

/// A bubble-free animated GIF that sizes to the GIF's own aspect ratio (like the
/// web app's `object-contain` img), capped at 240×300, with rounded corners that
/// hug the content instead of a fixed letterboxed box.
private struct AnimatedGifView: View {
    let url: URL
    @State private var aspect: CGFloat?

    var body: some View {
        KFAnimatedImage(url)
            .configure { $0.contentMode = .scaleAspectFill }
            .onSuccess { result in
                let s = result.image.size
                if s.width > 0, s.height > 0 { aspect = s.width / s.height }
            }
            .placeholder {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.yaplyBackground)
                    ProgressView().tint(Color.yaplyAccent)
                }
                .frame(width: 180, height: 140)
            }
            .fade(duration: 0.15)
            .aspectRatio(aspect ?? 1, contentMode: .fit)
            .frame(maxWidth: 240, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - File attachment

/// A compact pill for a `type: "file"` message — icon + filename, opens the
/// public media URL on tap (Safari / QuickLook).
private struct FileAttachmentBubble: View {
    let url: URL
    let isOwn: Bool
    @Environment(\.openURL) private var openURL

    private var filename: String {
        let raw = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        // Uploads are stored as "<uuid>-<original name>" — strip the uuid prefix.
        if let dash = raw.firstIndex(of: "-"),
           UUID(uuidString: String(raw[raw.startIndex..<dash])) != nil {
            return String(raw[raw.index(after: dash)...])
        }
        return raw
    }

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isOwn ? .white : Color.yaplyAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(filename)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isOwn ? .white : Color.yaplyPrimary)
                        .lineLimit(1)
                    Text("Tap to open")
                        .font(.system(size: 11))
                        .foregroundStyle(isOwn ? Color.white.opacity(0.8) : Color.yaplySecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 220, alignment: .leading)
            .background(
                Group {
                    if isOwn {
                        LinearGradient(
                            colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        Color.yaplyCard
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isOwn ? Color.clear : Color.yaplyBorderSoft, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sticker pop-in

/// iMessage-style scale/spring entrance the first time a sticker bubble appears.
private struct StickerPopIn: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    shown = true
                }
            }
    }
}

// MARK: - BubbleShape

private struct BubbleShape: Shape {
    let isOwn: Bool
    let radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let tl = CGPoint(x: rect.minX, y: rect.minY)
        let tr = CGPoint(x: rect.maxX, y: rect.minY)
        let bl = CGPoint(x: rect.minX, y: rect.maxY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY)
        let flatRadius: CGFloat = 4

        var path = Path()
        path.move(to: CGPoint(x: tl.x + radius, y: tl.y))
        path.addLine(to: CGPoint(x: tr.x - radius, y: tr.y))
        path.addQuadCurve(to: CGPoint(x: tr.x, y: tr.y + radius), control: tr)
        path.addLine(to: CGPoint(x: br.x, y: br.y - (isOwn ? flatRadius : radius)))
        path.addQuadCurve(to: CGPoint(x: br.x - (isOwn ? flatRadius : radius), y: br.y), control: br)
        path.addLine(to: CGPoint(x: bl.x + (isOwn ? radius : flatRadius), y: bl.y))
        path.addQuadCurve(to: CGPoint(x: bl.x, y: bl.y - (isOwn ? radius : flatRadius)), control: bl)
        path.addLine(to: CGPoint(x: tl.x, y: tl.y + radius))
        path.addQuadCurve(to: CGPoint(x: tl.x + radius, y: tl.y), control: tl)
        path.closeSubpath()
        return path
    }
}

private extension Date {
    var timeOnly: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: self)
    }
}
