import SwiftUI

// @mentions only exist in group chats. Modeled on CommandPaletteView, but
// tap-to-select only — SwiftUI's TextField gives us no caret to drive
// keyboard navigation from, matching CommandPaletteView's own no-nav behavior.
struct MentionOption: Identifiable {
    let id: String
    let everyone: Bool
    let userId: UUID?
    let username: String
    let displayName: String
    let avatarUrl: String?
}

struct MentionPaletteView: View {
    let options: [MentionOption]
    let onSelect: (MentionOption) -> Void
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MEMBERS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.yaplySecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }

            ForEach(options) { option in
                Button(action: { onSelect(option) }) {
                    HStack(spacing: 8) {
                        if option.everyone {
                            Circle()
                                .fill(Color.yaplyAccent)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Image(systemName: "at")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                        } else {
                            AvatarView(url: option.avatarUrl, name: option.displayName, size: 24)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.displayName)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.yaplyPrimary)
                                .lineLimit(1)
                            Text(option.everyone ? "Notify everyone" : "@\(option.username)")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.yaplySecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if option.id != options.last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Color.yaplySurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))
        .shadow(color: Color.yaplyShadow, radius: 8, y: -4)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
