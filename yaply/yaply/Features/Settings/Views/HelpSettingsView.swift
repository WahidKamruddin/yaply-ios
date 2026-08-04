import SwiftUI

private let faqs: [(q: String, a: String)] = [
    ("Are my messages actually private?", "Text messages are end-to-end encrypted — the app encrypts them on your device before sending, and only your and your recipients' devices can decrypt them. We (and anyone who might access our database) only ever see ciphertext. Media like images and files are not encrypted yet."),
    ("Why can't I read old messages on a new device?", "Each device generates its own encryption keys. Messages sent before a new device existed were sealed to your other devices' keys, so a brand-new device can't retroactively decrypt them. This is a known limitation — key backup/escrow would be needed to fix it, and we haven't built that yet."),
    ("I signed in with Google — can I set a password?", "No — password changes only apply to accounts created with email/password. Google accounts sign in through Google, so there's no yaply password to change."),
    ("How do I change my username?", "Go to Settings → Account and edit the username field, then Save changes. Usernames must be unique, at least 3 characters, and can only contain lowercase letters, numbers, underscores, dots, and hyphens."),
    ("Can I recover a deleted conversation?", "No — deleting a conversation removes it and its messages for you. If everyone in a direct message has left, the conversation and its messages are permanently deleted for both sides."),
    ("How do reminders, tasks, and events work?", "These live in the panel next to a conversation — accessible via the conversation header, or by typing slash commands like /remind, /create, /plan and /event directly in the message box."),
    ("Something's broken — what do I do?", "Check the known issues list below first — it might already be tracked. If not, use Report a Problem to send us the details directly."),
]

struct HelpSettingsView: View {
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(Color.yaplySecondary))
                Text("Frequently asked questions").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
            }
            Text("Can't find what you're looking for? Use Report a Problem to reach out directly.")
                .font(.subheadline)
                .foregroundStyle(Color.yaplySecondary)

            VStack(spacing: 0) {
                ForEach(Array(faqs.enumerated()), id: \.offset) { idx, faq in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expanded.contains(idx) { expanded.remove(idx) } else { expanded.insert(idx) }
                            }
                        } label: {
                            HStack {
                                Text(faq.q).font(.subheadline).fontWeight(.medium).foregroundStyle(Color.yaplyPrimary)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.yaplySecondary)
                                    .rotationEffect(.degrees(expanded.contains(idx) ? 180 : 0))
                            }
                        }
                        .buttonStyle(.plain)
                        if expanded.contains(idx) {
                            Text(faq.a).font(.subheadline).foregroundStyle(Color.yaplySecondary)
                        }
                    }
                    .padding(.vertical, 12)
                    if idx < faqs.count - 1 { Divider() }
                }
            }

            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "ladybug").font(.system(size: 13)).foregroundStyle(Color.yaplySecondary))
                Text("Still stuck? Head to **Report a Problem** in Settings — bugs there are actively worked on.")
                    .font(.subheadline)
                    .foregroundStyle(Color.yaplySecondary)
            }
            .padding(14)
            .background(Color.yaplyCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder))
        }
    }
}
