import SwiftUI
import Kingfisher

private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

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

    var swipeOffset: CGFloat = 0

    @State private var showDeleteConfirmation = false
    @State private var replyDragOffset: CGFloat = 0
    @State private var hasTriggeredReply = false

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
                        replyBlock(reply)
                    }

                    bubbleContent
                        .contextMenu {
                            if !message.isDeleted {
                                Section("React") {
                                    ForEach(quickEmojis, id: \.self) { emoji in
                                        Button(emoji) { onReact?(message.id, emoji) }
                                    }
                                }
                                Section {
                                    Button { onReply(message) } label: {
                                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                                    }
                                    Button { onReplyInThread?(message) } label: {
                                        Label("Reply in Thread", systemImage: "bubble.left.and.bubble.right")
                                    }
                                    if isOwn {
                                        Button("Delete", role: .destructive) { showDeleteConfirmation = true }
                                    }
                                }
                            }
                        }
                        .yaplyConfirm(
                            isPresented: $showDeleteConfirmation,
                            title: "Delete message",
                            message: "This will delete the message for everyone.",
                            icon: "trash.fill",
                            confirmLabel: "Delete"
                        ) { onDelete(message.id) }

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

    @ViewBuilder
    private var bubbleContent: some View {
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

    // MARK: - Reply preview block

    private func replyBlock(_ reply: DecryptedMessage) -> some View {
        Button {
            onQuotationClick?(reply.id)
        } label: {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.yaplyAccent)
                    .frame(width: 2, height: 22)
                    .padding(.horizontal, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.senderProfile?.name ?? "Unknown")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.yaplyAccent)
                        .lineLimit(1)
                    Text(replyPreview(reply))
                        .font(.system(size: 12))
                        .italic(reply.isDeleted)
                        .foregroundStyle(reply.isDeleted ? Color.yaplySecondary.opacity(0.7) : Color.yaplySecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.trailing, 14)
            }
            .frame(height: 36)
            .background(Color.yaplyTint)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorderSoft, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func replyPreview(_ reply: DecryptedMessage) -> String {
        if reply.isDeleted { return "Message deleted" }
        switch reply.type {
        case "sticker": return "Sticker"
        case "gif": return "GIF"
        case "image": return "📷 Photo"
        default: return String(reply.content.prefix(60))
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
