import SwiftUI

struct InAppBannerView: View {
    let notification: InAppNotification
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "message.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.yaplyAccent)
                .frame(width: 36, height: 36)
                .background(Color.yaplyAccent.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
                Text("Sent a message")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.yaplySecondary)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.yaplySecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.yaplyShadow, radius: 12, y: 4)
        .padding(.horizontal, 16)
        .onTapGesture(perform: onTap)
    }
}
