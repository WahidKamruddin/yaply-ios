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
                    PresenceDotView(isOnline: isOnline, borderColor: .yaplyBackground, size: 12)
                }
            }

            // Text content
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName)
                        .font(.display(15, weight: .semibold))
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
                        Text(item.unreadCount > 99 ? "99+" : "\(item.unreadCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Color.yaplyAccent)
                            .clipShape(Capsule())
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
        .background(.clear)
    }
}

// MARK: — Presence dot

struct PresenceDotView: View {
    let isOnline: Bool
    var borderColor: Color = .yaplyBackground
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(isOnline ? Color.yaplyOnline : Color.yaplyOffline)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(borderColor, lineWidth: 2))
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
            .fill(
                LinearGradient(
                    colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
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
