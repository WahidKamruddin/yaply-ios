import SwiftUI

// Pushed destination for a single Settings row (Account/Billing/Privacy/
// Terms/Help/Report) — reached only by tapping a row in SettingsView.
struct SettingsDetailView: View {
    let tab: SettingsTab
    let userId: UUID
    let userEmail: String

    var body: some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.yaplyBackground)
        .navigationTitle(tab.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .account: AccountSettingsView(userId: userId, userEmail: userEmail)
        case .devices: DeviceSettingsView(userId: userId)
        case .billing: BillingSettingsView()
        case .privacy: PrivacySettingsView()
        case .terms: TermsSettingsView()
        case .help: HelpSettingsView()
        case .report: ReportProblemView()
        }
    }
}
