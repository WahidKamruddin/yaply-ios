import SwiftUI
import UIKit

// Shown at the top of the conversation list when the user has denied notification
// permission.
//
// Without this a denial is completely invisible: the prompt is declined once at
// sign-in, notifications silently never arrive, and the feature reads as broken
// rather than off. iOS offers no way to re-prompt — the only route back is the
// Settings app — so surfacing it in the app is the only way anyone finds out.
struct NotificationsDisabledBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(Color.orange.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                Text("You won't be told about new messages. Tap to turn them on.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.yaplySecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.yaplySecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.yaplyShadow, radius: 12, y: 4)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notifications are off. Tap to open Settings and turn them on.")
    }
}
