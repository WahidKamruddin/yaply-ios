import SwiftUI

// Visual language for the plan (availability) and confirmed-event screens,
// ported from the web landing page's EventFlowDemo. Web counterpart: the
// `.plan-*` rules in src/styles.css — keep the values in step.

// MARK: - Best slot

/// Same rule as web's `src/features/chat/lib/bestSlot.ts`:
/// live counts (everyone else's saved availability + my local selection),
/// highest count across every week, ties → earliest, nothing below two people.
enum BestSlot {
    static let minCount = 2

    static func liveCounts(
        availability: [YaplyEventAvailability],
        currentUserId: UUID,
        mySlots: Set<String>
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for av in availability where av.userId != currentUserId {
            for slot in av.slots { counts[slot, default: 0] += 1 }
        }
        for slot in mySlots { counts[slot, default: 0] += 1 }
        return counts
    }

    /// Slot keys are same-format UTC ISO strings, so string order is chronological.
    static func find(_ counts: [String: Int]) -> (slot: String, count: Int)? {
        var best: (slot: String, count: Int)?
        for (slot, count) in counts where count >= minCount {
            if let b = best, count < b.count || (count == b.count && slot >= b.slot) { continue }
            best = (slot, count)
        }
        return best
    }

    /// Heat level 0–3 by share of members free (web `heatLevel`).
    static func level(count: Int, total: Int) -> Int {
        guard count > 0 else { return 0 }
        let ratio = Double(count) / Double(max(1, total))
        if ratio <= 1.0 / 3.0 { return 1 }
        if ratio <= 2.0 / 3.0 { return 2 }
        return 3
    }
}

// MARK: - Colors

enum PlanStyle {
    static let gradient = LinearGradient(
        colors: [Color.yaplyAccent, Color.yaplyAccentDark],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    // #8fb8ff / #2f6fe0 — the landing's `--sky`
    static let sky = Color(
        light: Color(red: 0.184, green: 0.435, blue: 0.878),
        dark: Color(red: 0.561, green: 0.722, blue: 1.0)
    )

    static func heatFill(_ level: Int) -> Color {
        switch level {
        case 1: return Color(light: Color.yaplyAccent.opacity(0.18), dark: Color.yaplyAccent.opacity(0.22))
        case 2: return Color(light: Color.yaplyAccent.opacity(0.40), dark: Color.yaplyAccent.opacity(0.45))
        case 3: return Color(
            light: Color(red: 0.231, green: 0.435, blue: 0.878).opacity(0.85),
            dark: Color.yaplyAccent.opacity(0.8)
        )
        default: return Color.yaplyTint
        }
    }
}

// MARK: - Badge (mono uppercase pill)

struct PlanBadge: View {
    let text: String
    var uppercase = true
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(uppercase ? text.uppercased() : text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(uppercase ? 1 : 0)
                .lineLimit(1)
        }
        .foregroundStyle(PlanStyle.sky)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(PlanStyle.sky.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(PlanStyle.sky.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - Pill buttons

struct PlanPillStyle: ButtonStyle {
    var primary = false
    var fill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(primary ? Color.white : Color.yaplyTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: fill ? .infinity : nil)
            .background {
                if primary { Capsule().fill(PlanStyle.gradient) }
                else { Capsule().fill(Color.yaplyTint) }
            }
            .overlay { if !primary { Capsule().stroke(Color.yaplyBorder, lineWidth: 1) } }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct PlanRoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.yaplyTertiary)
                .frame(width: 30, height: 30)
                .background(Color.yaplyTint, in: Circle())
                .overlay(Circle().stroke(Color.yaplyBorder, lineWidth: 1))
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Best-slot glow

private struct BestGlow: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .shadow(
                color: PlanStyle.sky.opacity(active ? (reduceMotion ? 0.45 : (pulse ? 0.55 : 0)) : 0),
                radius: active ? 7 : 0
            )
            .zIndex(active ? 1 : 0)
            .onAppear { startIfNeeded() }
            .onChange(of: active) { startIfNeeded() }
    }

    private func startIfNeeded() {
        guard active, !reduceMotion else { pulse = false; return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
    }
}

extension View {
    func planBestGlow(_ active: Bool) -> some View { modifier(BestGlow(active: active)) }
}

// MARK: - Stacked faces

struct PlanStackedFaces: View {
    let people: [(id: UUID, name: String, avatarUrl: String?)]
    var size: CGFloat = 27
    var max = 6

    var body: some View {
        HStack(spacing: -7) {
            ForEach(Array(people.prefix(max).enumerated()), id: \.element.id) { _, p in
                AvatarView(url: p.avatarUrl, name: p.name, size: size)
                    .overlay(Circle().stroke(Color.yaplyCard, lineWidth: 2))
            }
        }
    }
}
