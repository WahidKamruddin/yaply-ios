import SwiftUI

// Blocking first-login prompt — mirrors web's UsernameSetupModal
// (non-dismissable Radix dialog). Presented via .fullScreenCover from
// ContentView whenever profiles.username_set is false.
struct UsernameSetupView: View {
    let userId: UUID
    let suggestedUsername: String
    let onComplete: () -> Void

    @State private var vm: UsernameSetupViewModel
    @FocusState private var isFocused: Bool

    init(userId: UUID, suggestedUsername: String, onComplete: @escaping () -> Void) {
        self.userId = userId
        self.suggestedUsername = suggestedUsername
        self.onComplete = onComplete
        _vm = State(initialValue: UsernameSetupViewModel(userId: userId, suggestedUsername: suggestedUsername))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.yaplyAccent.opacity(0.15))
                        .frame(width: 88, height: 88)
                        .blur(radius: 8)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                        .overlay(Circle().stroke(Color.yaplyTint, lineWidth: 4))
                    Image(systemName: "at")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 4) {
                    Text("Choose a username")
                        .font(.display(18, weight: .bold))
                        .foregroundStyle(Color.yaplyPrimary)
                    Text("People will find and mention you by this.")
                        .font(.subheadline)
                        .foregroundStyle(Color.yaplySecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("@")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Color.yaplySecondary)
                        TextField("username", text: $vm.username)
                            .font(.system(size: 15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .onChange(of: vm.username) { _, newValue in
                                vm.checkAvailability()
                            }
                            .onSubmit { Task { await save() } }
                        availabilityIcon
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.yaplyTint)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))

                    if vm.availability == .taken {
                        Text("That username is taken.")
                            .font(.caption)
                            .foregroundStyle(Color.yaplyDanger)
                    }
                    if let error = vm.error, vm.availability != .taken {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.yaplyDanger)
                    }
                }

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if vm.isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "checkmark")
                            Text("Continue")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.yaplyAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(vm.isSaving || vm.username.trimmingCharacters(in: .whitespaces).isEmpty || vm.availability != .available)
            }
            .padding(24)
            .background(Color.yaplySurface)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: Color.black.opacity(0.25), radius: 24, y: 10)
            .padding(.horizontal, 32)
            .frame(maxWidth: 400)
        }
        .interactiveDismissDisabled()
        .task {
            isFocused = true
            vm.checkAvailability()
        }
    }

    private func save() async {
        guard await vm.save() else { return }
        onComplete()
    }

    @ViewBuilder
    private var availabilityIcon: some View {
        switch vm.availability {
        case .checking:
            ProgressView().controlSize(.mini)
        case .available:
            Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.yaplyMint)
        case .taken:
            Image(systemName: "xmark").font(.caption).foregroundStyle(Color.yaplyDanger)
        case .idle, .invalid:
            EmptyView()
        }
    }
}
