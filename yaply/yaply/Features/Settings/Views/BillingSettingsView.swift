import SwiftUI

private struct BillingPlan {
    let name: String
    let price: String
    let period: String
    let current: Bool
    let features: [String]
}

private let plans: [BillingPlan] = [
    BillingPlan(
        name: "Free", price: "$0", period: "forever", current: true,
        features: [
            "Unlimited direct messages & groups",
            "End-to-end encrypted text",
            "Tasks, Notes, Reminders, Events",
            "Albums & Budgets",
        ]
    ),
    BillingPlan(
        name: "Plus", price: "$4", period: "/month", current: false,
        features: [
            "Everything in Free",
            "Larger media uploads",
            "Custom stickers",
            "Priority support",
        ]
    ),
]

struct BillingSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Color.yaplySecondary))
                Text("Plan & billing").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
            }
            Text("yaply is free while we're building out the core experience. Paid plans are a preview of what's coming — nothing here is billed yet.")
                .font(.subheadline)
                .foregroundStyle(Color.yaplySecondary)

            ForEach(plans, id: \.name) { plan in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(plan.name).font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
                        if plan.current {
                            Text("CURRENT")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.yaplyAccent)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.yaplyTintStrong)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(plan.price).font(.title2).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
                        Text(plan.period).font(.caption).foregroundStyle(Color.yaplySecondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.features, id: \.self) { f in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color.yaplyMint)
                                Text(f).font(.caption).foregroundStyle(Color.yaplySecondary)
                            }
                        }
                    }
                    Text(plan.current ? "Current plan" : "Coming soon")
                        .font(.subheadline).fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(plan.current ? Color.yaplySecondary : .white)
                        .background(plan.current ? Color.yaplyTint : Color.yaplyAccent.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(16)
                .background(plan.current ? Color.yaplyTint : Color.yaplyCard)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(plan.current ? Color.yaplyAccent.opacity(0.4) : Color.yaplyBorder))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Payment method").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
                Text("No payment method on file — you're not being charged.")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yaplyCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yaplyBorder))
        }
    }
}
