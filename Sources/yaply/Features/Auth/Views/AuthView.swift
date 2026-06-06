import SwiftUI

struct AuthView: View {
    @Environment(AuthService.self) private var authService
    @State private var vm: AuthViewModel

    init(authService: AuthService) {
        _vm = State(initialValue: AuthViewModel(authService: authService))
    }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo / wordmark
                VStack(spacing: 8) {
                    Circle()
                        .fill(Color.yaplyAccent)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Text("Y")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                        )
                    Text("yaply")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.yaplyPrimary)
                }

                // Form card
                VStack(spacing: 16) {
                    if vm.isSignUp {
                        YaplyTextField(placeholder: "Username", text: $vm.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    YaplyTextField(placeholder: "Email", text: $vm.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    YaplyTextField(placeholder: "Password", text: $vm.password, isSecure: true)

                    if let msg = vm.errorMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.contains("Check your email") ? Color.green : Color.red)
                            .multilineTextAlignment(.center)
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
                    .disabled(vm.isLoading)
                }
                .padding(24)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: Color.yaplyShadow, radius: 12, y: 4)

                // Toggle sign in / sign up
                Button(action: {
                    vm.isSignUp.toggle()
                    vm.errorMessage = nil
                }) {
                    HStack(spacing: 4) {
                        Text(vm.isSignUp ? "Already have an account?" : "Don't have an account?")
                            .foregroundStyle(Color.yaplySecondary)
                        Text(vm.isSignUp ? "Sign In" : "Sign Up")
                            .foregroundStyle(Color.yaplyAccent)
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
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
        .background(Color.yaplyBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yaplyBorder, lineWidth: 1)
        )
    }
}
