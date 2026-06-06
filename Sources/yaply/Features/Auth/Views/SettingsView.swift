import SwiftUI

struct SettingsView: View {
    @Environment(AuthService.self) private var authService

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            List {
                Section {
                    Button(role: .destructive) {
                        Task { try? await authService.signOut() }
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign Out")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
