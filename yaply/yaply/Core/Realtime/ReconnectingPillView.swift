import SwiftUI

// Shown while `RealtimeConnectionMonitor` is recovering a dead realtime connection.
//
// Deliberately a non-blocking pill rather than a skeleton or an overlay: a dead socket
// does not mean the data is unavailable. Fetches and sends go over HTTPS and keep
// working — only *live* updates stop — so the content underneath is correct and usable,
// just frozen. Hiding it behind a loading state would be a lie.
struct ReconnectingPillView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.yaplySecondary)
            Text("Reconnecting…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.yaplySecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: Color.yaplyShadow, radius: 10, y: 3)
    }
}
