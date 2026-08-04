import SwiftUI

private let sections: [(title: String, body: String)] = [
    ("What we store", "Your profile (name, username, avatar, bio, birthdate), device public keys, and message metadata (who a conversation is with, timestamps, and conversation membership) are stored in our database. Message text content is end-to-end encrypted — we store ciphertext, not plaintext."),
    ("What we can and cannot see", "We cannot read the text of your messages. Encryption keys are generated and stored on your own devices; our servers only ever see encrypted content. We can see who you talk to, when, and how often, since that metadata isn't encrypted. Media (images, files, stickers) is not currently encrypted."),
    ("Third parties", "We use Supabase for database, auth, and storage, and Resend to deliver bug report emails you submit. We do not sell your data or share it with advertisers."),
    ("Your controls", "You can edit or delete your profile information at any time from Account settings. Deleting a conversation removes it and its messages from your view; deleting your account removes your profile data."),
    ("Changes to this policy", "This is a placeholder policy while yaply is in active development. We'll notify you in-app before any material change takes effect."),
]

struct PrivacySettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "shield").font(.system(size: 14)).foregroundStyle(Color.yaplySecondary))
                Text("Privacy Policy").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
            }
            Text("Draft — last updated for preview purposes only.")
                .font(.caption)
                .foregroundStyle(Color.yaplySecondary)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(sections, id: \.title) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title).font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
                        Text(s.body).font(.subheadline).foregroundStyle(Color.yaplySecondary)
                    }
                }
            }
        }
    }
}
