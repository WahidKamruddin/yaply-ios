import SwiftUI
import Kingfisher

struct ConversationRowView: View {
    let item: ConversationListItem
    let currentUserId: UUID

    private var displayName: String { item.displayName(currentUserId: currentUserId) }
    private var other: MemberSummary? { item.otherMember(currentUserId: currentUserId) }
    private var isOnline: Bool { !item.isGroup && (other?.profile.effectiveOnline ?? false) }

    // Mirrors the server's push_targets_for_message badge rule: a muted chat
    // still surfaces its unread @mentions unless "mute everything" is also on.
    private var displayUnreadCount: Int {
        item.isMuted ? (item.muteMentions ? 0 : item.mentionUnreadCount) : item.unreadCount
    }
    private var isMentionOnlyBadge: Bool { item.isMuted && displayUnreadCount > 0 }

    // Messenger's list reads slightly roomier; iMessage's is more compact.
    private var rowVerticalPadding: CGFloat {
        switch ChatStyle.current {
        case .yaply: return 10
        case .messenger: return 12
        case .imessage: return 8
        }
    }

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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(item.updatedAt.relativeShort)
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary)
                }

                HStack {
                    Text(item.lastMessage.map { $0.previewText } ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(displayUnreadCount > 0 ? Color.yaplyPrimary : Color.yaplySecondary)
                        .fontWeight(displayUnreadCount > 0 ? .medium : .regular)
                        .lineLimit(1)
                    Spacer()
                    if displayUnreadCount > 0 {
                        Text(isMentionOnlyBadge ? "@" : (displayUnreadCount > 99 ? "99+" : "\(displayUnreadCount)"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(isMentionOnlyBadge ? Color.yaplyAccent.opacity(0.7) : Color.yaplyAccent)
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
        .padding(.vertical, rowVerticalPadding)
        .padding(.horizontal, 16)
        .background(.clear)
        // Whole row is the tap target, not just the avatar and text: a clear
        // background isn't hit-testable, so the gaps and trailing space ignored taps.
        .contentShape(Rectangle())
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

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let url, let imageUrl = URL(string: url) {
            // Kingfisher rather than AsyncImage: AsyncImage has no cache of its
            // own, so every recycle of a message row or conversation row
            // re-downloaded and re-decoded the avatar on the render thread --
            // at full resolution, into a 28pt circle. Downsampling to the
            // circle's pixel size is the whole point of the swap.
            KFImage(imageUrl)
                .downsampling(size: CGSize(width: size * displayScale, height: size * displayScale))
                .backgroundDecode()
                .placeholder { placeholderAvatar }
                .onFailureView { fallbackAvatar }
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            fallbackAvatar
        }
    }

    // Neutral silhouette shown while the profile photo is still loading.
    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.yaplyTint)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(Color.yaplySecondary)
            )
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
