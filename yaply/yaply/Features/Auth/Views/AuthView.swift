import SwiftUI

struct AuthView: View {
    @Environment(AuthService.self) private var authService
    @State private var vm: AuthViewModel
    @Namespace private var segmentNamespace

    init(authService: AuthService) {
        _vm = State(initialValue: AuthViewModel(authService: authService))
    }

    private var title: String {
        vm.isSignUp ? "Create your account." : "Welcome back."
    }

    private var subtitle: String {
        vm.isSignUp ? "Takes less than a minute." : "Sign in to keep the conversation going."
    }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 40)

                    // Logo mark + wordmark, side by side
                    HStack(spacing: 10) {
                        YaplyLogoMark(size: 40)
                        Text("yaply")
                            .font(.display(30, weight: .medium))
                            .foregroundStyle(Color.yaplyPrimary)
                    }
                    .shadow(color: Color.yaplyLogoEnd.opacity(0.2), radius: 10, y: 4)

                    VStack(spacing: 4) {
                        Text(title)
                            .font(.display(24, weight: .bold))
                            .foregroundStyle(Color.yaplyPrimary)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    .multilineTextAlignment(.center)

                    // Form card
                    VStack(spacing: 16) {
                        modeSegment

                        YaplyTextField(placeholder: "Email", text: $vm.email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        YaplyPasswordField(placeholder: "Password", text: $vm.password)
                            .textContentType(vm.isSignUp ? .newPassword : .password)

                        if vm.isSignUp && !vm.password.isEmpty {
                            passwordStrengthView
                        }

                        if vm.isSignUp {
                            YaplyPasswordField(placeholder: "Confirm password", text: $vm.confirmPassword)
                                .textContentType(.newPassword)
                        }

                        if let msg = vm.errorMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(Color.yaplyDanger)
                                .multilineTextAlignment(.center)
                        }
                        if let msg = vm.infoMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(Color.yaplyMint)
                                .multilineTextAlignment(.center)
                        }
                        if vm.unconfirmedEmail != nil {
                            Button(vm.isResending ? "Resending…" : "Resend confirmation email") {
                                Task { await vm.resendConfirmation() }
                            }
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.yaplyAccent)
                            .disabled(vm.isResending)
                        }

                        Button(action: { Task { await vm.submit() } }) {
                            if vm.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(vm.isSignUp ? "Create Account" : "Sign In")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.yaplyAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(isSubmitDisabled)

                        HStack(spacing: 8) {
                            Rectangle().fill(Color.yaplyBorder).frame(height: 1)
                            Text("or continue with")
                                .font(.caption)
                                .foregroundStyle(Color.yaplySecondary)
                                .fixedSize()
                            Rectangle().fill(Color.yaplyBorder).frame(height: 1)
                        }
                        .padding(.top, 4)

                        Button(action: { Task { await vm.signInWithGoogle() } }) {
                            HStack(spacing: 8) {
                                if vm.isGoogleLoading {
                                    ProgressView().tint(Color.yaplyAccent)
                                } else {
                                    GoogleLogoMark(size: 18)
                                    Text("Continue with Google")
                                        .font(.system(size: 15, weight: .medium))
                                }
                            }
                            .foregroundStyle(Color.yaplyPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))
                        .disabled(vm.isGoogleLoading)
                    }
                    .padding(24)
                    .background(Color.yaplySurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: Color.yaplyShadow, radius: 12, y: 4)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Sign in / Sign up segmented control

    private var modeSegment: some View {
        HStack(spacing: 3) {
            segmentButton(title: "Sign in", selected: !vm.isSignUp) { switchMode(isSignUp: false) }
            segmentButton(title: "Sign up", selected: vm.isSignUp) { switchMode(isSignUp: true) }
        }
        .padding(3)
        .background(Color.yaplyTint)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.yaplyBorder, lineWidth: 1))
    }

    private func segmentButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .white : Color.yaplySecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    if selected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .matchedGeometryEffect(id: "auth-seg-thumb", in: segmentNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func switchMode(isSignUp: Bool) {
        guard vm.isSignUp != isSignUp else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            vm.isSignUp = isSignUp
        }
        vm.errorMessage = nil
        vm.infoMessage = nil
        vm.unconfirmedEmail = nil
        vm.confirmPassword = ""
    }

    // MARK: - Password strength

    private var passwordStrengthView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(strengthBarColor(index: i))
                        .frame(height: 4)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.passwordStrength)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 5) {
                ForEach(vm.passwordChecks) { check in
                    HStack(spacing: 5) {
                        Image(systemName: check.met ? "checkmark" : "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text(check.label)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(check.met ? Color.yaplyMint : Color.yaplySecondary)
                }
            }
        }
    }

    private func strengthBarColor(index: Int) -> Color {
        switch vm.passwordStrength {
        case .weak: return index == 0 ? Color.yaplyDanger : Color.yaplyTint
        case .fair: return index < 2 ? Color.orange : Color.yaplyTint
        case .good: return index < 3 ? Color.yaplyAccent : Color.yaplyTint
        case .strong: return Color.yaplyMint
        }
    }

    private var isSubmitDisabled: Bool {
        if vm.isLoading { return true }
        guard vm.isSignUp else { return false }
        return !PasswordStrength.isStrongEnough(vm.password) || vm.password != vm.confirmPassword
    }
}

// MARK: — Shared text field component

struct YaplyTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .padding(14)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yaplyBorder, lineWidth: 1)
        )
    }
}

// MARK: — Password field with show/hide toggle

struct YaplyPasswordField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yaplySecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yaplyBorder, lineWidth: 1)
        )
    }
}
