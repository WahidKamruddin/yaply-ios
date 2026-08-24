import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case account, devices, billing, privacy, terms, help, report

    var id: String { rawValue }

    var label: String {
        switch self {
        case .account: return "Account"
        case .devices: return "Devices"
        case .billing: return "Billing"
        case .privacy: return "Privacy Policy"
        case .terms: return "Terms of Service"
        case .help: return "Help"
        case .report: return "Report a Problem"
        }
    }

    var icon: String {
        switch self {
        case .account: return "person"
        case .devices: return "laptopcomputer.and.iphone"
        case .billing: return "creditcard"
        case .privacy: return "shield"
        case .terms: return "doc.text"
        case .help: return "questionmark.circle"
        case .report: return "ladybug"
        }
    }
}

// Settings menu: a plain list of rows. Tapping a row pushes the matching
// sub-page (SettingsDetailView) via the app router — navigation happens
// through row taps, not a top tab bar.
struct SettingsView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    router.push(.settingsDetail(tab))
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.yaplyTint)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Image(systemName: tab.icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.yaplySecondary)
                            )
                        Text(tab.label)
                            .font(.subheadline)
                            .foregroundStyle(Color.yaplyPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.yaplySurface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.yaplyBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
