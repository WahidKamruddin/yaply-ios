import Foundation

@Observable
final class AuthViewModel {
    var email = ""
    var password = ""
    var confirmPassword = ""
    var isSignUp = false
    var isLoading = false
    var errorMessage: String?
    var infoMessage: String?
    var isGoogleLoading = false

    // Surfaced when sign-in fails with "email not confirmed" — mirrors web's
    // resend-confirmation affordance.
    var unconfirmedEmail: String?
    var isResending = false

    var passwordChecks: [PasswordCheck] { PasswordStrength.checks(for: password) }
    var passwordStrength: PasswordStrengthLevel { PasswordStrength.level(for: password) }

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    func submit() async {
        errorMessage = nil
        infoMessage = nil
        unconfirmedEmail = nil
        isLoading = true
        defer { isLoading = false }

        do {
            if isSignUp {
                // Same five-check password policy as web — enforced here too
                // (not just via the disabled submit button) in case this is
                // ever called from somewhere that skips that gating.
                guard PasswordStrength.isStrongEnough(password) else {
                    errorMessage = "Your password doesn't meet all the requirements below."
                    return
                }
                guard password == confirmPassword else {
                    errorMessage = "Passwords do not match."
                    return
                }
                // No username collected here — matches web. A placeholder
                // username is seeded server-side (handle_new_user trigger)
                // and the app prompts to replace it on first login.
                try await authService.signUp(email: email, password: password)
                infoMessage = "Check your inbox to confirm your email before signing in."
                isSignUp = false
                password = ""
                confirmPassword = ""
            } else {
                do {
                    try await authService.signIn(email: email, password: password)
                } catch {
                    if error.localizedDescription.lowercased().contains("email not confirmed") {
                        unconfirmedEmail = email
                    }
                    throw error
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resendConfirmation() async {
        guard let unconfirmedEmail else { return }
        isResending = true
        errorMessage = nil
        defer { isResending = false }
        do {
            try await authService.resendConfirmationEmail(email: unconfirmedEmail)
            infoMessage = "Confirmation email resent — check your inbox."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithGoogle() async {
        errorMessage = nil
        isGoogleLoading = true
        defer { isGoogleLoading = false }
        do {
            try await authService.signInWithGoogle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
