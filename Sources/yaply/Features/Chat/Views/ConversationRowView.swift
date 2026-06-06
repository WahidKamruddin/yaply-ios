import SwiftUI

struct ConversationRowView: View {
    let item: ConversationListItem
    let currentUserId: UUID

    private var displayName: String { item.displayName(currentUserId: currentUserId) }
    private var other: MemberSummary? { item.otherMember(currentUserId: currentUserId) }
    private var isOnline: Bool { !item.isGroup && (other?.profile.isOnline ?? false) }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    url: item.isGroup ? item.avatarUrl : other?.profile.avatarUrl,
                    name: displayName,
                    size: 48
                )
                if !item.isGroup {
                    Circle()
                        .fill(isOnline ? Color.green : Color.yaplySecondary)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                }
            }

            // Text content
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(item.updatedAt.relativeShort)
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary)
                }

                HStack {
                    Text(item.lastMessage.map { $0.isDeleted ? "Message deleted" : $0.content } ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(item.unreadCount > 0 ? Color.yaplyPrimary : Color.yaplySecondary)
                        .fontWeight(item.unreadCount > 0 ? .medium : .regular)
                        .lineLimit(1)
                    Spacer()
                    if item.unreadCount > 0 {
                        Circle()
                            .fill(Color.yaplyAccent)
                            .frame(width: 8, height: 8)
                    }
                    if item.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color.white)
    }
}

// MARK: — Reusable avatar

struct AvatarView: View {
    let url: String?
    let name: String
    let size: CGFloat

    var body: some View {
        if let url, let imageUrl = URL(string: url) {
            AsyncImage(url: imageUrl) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    fallbackAvatar
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            fallbackAvatar
        }
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(Color.yaplyAccent)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: — Date formatting helper

private extension Date {
    var relativeShort: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return fmt.string(from: self)
        } else if cal.isDateInYesterday(self) {
            return "Yesterday"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM/dd/yy"
            return fmt.string(from: self)
        }
    }
}
