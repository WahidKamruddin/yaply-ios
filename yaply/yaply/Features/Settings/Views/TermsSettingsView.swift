import SwiftUI

private let sections: [(title: String, body: String)] = [
    ("1. Acceptance of terms", "By using yaply you agree to these terms. yaply is currently in active development — features, availability, and these terms may change without prior notice."),
    ("2. Your account", "You're responsible for keeping your login credentials secure and for activity that happens under your account. You must be able to legally use messaging services in your jurisdiction."),
    ("3. Acceptable use", "No harassment, spam, illegal content, or attempts to disrupt or reverse-engineer the service. We may suspend accounts that violate this."),
    ("4. Content ownership", "You retain ownership of the messages, media, and content you send. Encrypted content is unreadable to us; unencrypted media you upload is stored to provide the service and is not used for any other purpose."),
    ("5. No warranty", "yaply is provided \"as is\" during development, without warranty of any kind, including around uptime, data retention, or fitness for a particular purpose."),
    ("6. Termination", "You may stop using yaply and delete your account at any time. We may suspend accounts for violations of these terms."),
]

struct TermsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(Color.yaplySecondary))
                Text("Terms of Service").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
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
