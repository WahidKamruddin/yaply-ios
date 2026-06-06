import SwiftUI

struct MessageBubbleView: View {
    let message: DecryptedMessage
    let isOwn: Bool
    let onReply: (DecryptedMessage) -> Void
    let onDelete: (UUID) -> Void

    @State private var showActions = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwn { Spacer(minLength: 60) }

            if !isOwn {
                AvatarView(
                    url: message.senderProfile?.avatarUrl,
                    name: message.senderProfile?.name ?? "?",
                    size: 28
                )
            }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                if !isOwn, let profile = message.senderProfile {
                    Text(profile.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.yaplyTertiary)
                        .padding(.leading, 4)
                }

                bubbleContent
                    .onLongPressGesture { showActions = true }
                    .confirmationDialog("Message", isPresented: $showActions) {
                        Button("Reply") { onReply(message) }
                        if isOwn && !message.isDeleted {
                            Button("Delete", role: .destructive) { onDelete(message.id) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }

                Text(message.serverTimestamp.timeOnly)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.yaplySecondary)
                    .padding(.horizontal, 4)
            }

            if !isOwn { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            Text("Message deleted")
                .font(.subheadline)
                .italic()
                .foregroundStyle(Color.yaplySecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(BubbleShape(isOwn: isOwn))
                .overlay(
                    BubbleShape(isOwn: isOwn)
                        .stroke(Color.yaplyBorder, lineWidth: 1)
                )
        } else {
            Text(message.content)
                .font(.system(size: 15))
                .foregroundStyle(isOwn ? .white : Color.yaplyPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isOwn ? Color.yaplyAccent : Color.white)
                .clipShape(BubbleShape(isOwn: isOwn))
                .shadow(color: Color.yaplyShadow, radius: 2, y: 1)
        }
    }
}

// Rounded rectangle with one flat corner to create a chat bubble effect
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
        path.addQuadCurve(
            to: CGPoint(x: br.x - (isOwn ? flatRadius : radius), y: br.y),
            control: br
        )
        path.addLine(to: CGPoint(x: bl.x + (isOwn ? radius : flatRadius), y: bl.y))
        path.addQuadCurve(
            to: CGPoint(x: bl.x, y: bl.y - (isOwn ? radius : flatRadius)),
            control: bl
        )
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
