import SwiftUI

// Shared row used across every Friends tab. AvatarView/PresenceDotView come
// from ConversationRowView.swift.
struct UserRowView<Trailing: View>: View {
    let name: String
    let username: String
    let avatarUrl: String?
    let isOnline: Bool
    var subtitle: String?
    let onTap: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(url: avatarUrl, name: name, size: 44)
                    PresenceDotView(isOnline: isOnline, borderColor: .yaplyBackground, size: 11)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                        .lineLimit(1)
                    Text(subtitle ?? "@\(username)")
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary)
                        .lineLimit(1)
                }

                Spacer()

                trailing()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

extension UserRowView where Trailing == EmptyView {
    init(name: String, username: String, avatarUrl: String?, isOnline: Bool, subtitle: String? = nil, onTap: @escaping () -> Void) {
        self.init(name: name, username: username, avatarUrl: avatarUrl, isOnline: isOnline, subtitle: subtitle, onTap: onTap, trailing: { EmptyView() })
    }
}

// Small pill button used for Accept/Decline/Cancel/Unblock/Add trailing actions.
struct FriendActionButton: View {
    let title: String
    var style: Style = .primary
    let action: () -> Void

    enum Style { case primary, secondary, destructive, disabled }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(background)
                .clipShape(Capsule())
        }
        .disabled(style == .disabled)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .yaplyAccent
        case .destructive: return .white
        case .disabled: return .yaplySecondary
        }
    }

    private var background: Color {
        switch style {
        case .primary: return .yaplyAccent
        case .secondary: return .yaplyAccent.opacity(0.12)
        case .destructive: return .yaplyDanger
        case .disabled: return .yaplyBorder
        }
    }
}
