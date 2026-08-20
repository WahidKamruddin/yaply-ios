import SwiftUI

// Shimmering placeholder block — the iOS equivalent of web's `.skeleton`
// utility in styles.css (same sweep timing, same yaplyTint/yaplyTintStrong
// tokens) so loading states feel identical across platforms.
struct SkeletonView: View {
    var cornerRadius: CGFloat = 6
    // Per-row stagger so a list of skeletons reads as progressive loading
    // rather than blinking in lockstep — mirrors web's `delay` prop.
    var delay: Double = 0
    @State private var phase: CGFloat = -0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.yaplyTint)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.yaplyTintStrong, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.8).delay(delay).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
    }
}

// MARK: - Conversation row skeleton (mirrors ConversationRowView layout)

struct ConversationRowSkeleton: View {
    var delay: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            SkeletonView(cornerRadius: 24, delay: delay)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SkeletonView(delay: delay).frame(width: 120, height: 14)
                    Spacer()
                    SkeletonView(delay: delay).frame(width: 32, height: 11)
                }
                SkeletonView(delay: delay).frame(width: 180, height: 12)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Dashboard row skeleton (mirrors HomeView's remindersCard/eventsCard rows)

struct DashboardRowSkeleton: View {
    var delay: Double = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SkeletonView(cornerRadius: 3, delay: delay)
                .frame(width: 11, height: 11)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonView(delay: delay).frame(width: 160, height: 13)
                SkeletonView(delay: delay).frame(width: 100, height: 11)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Dashboard friend tile skeleton (mirrors HomeView's friendsCard grid)

struct DashboardFriendSkeleton: View {
    var delay: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            SkeletonView(cornerRadius: 14, delay: delay).frame(width: 28, height: 28)
            SkeletonView(delay: delay).frame(width: 60, height: 13)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
