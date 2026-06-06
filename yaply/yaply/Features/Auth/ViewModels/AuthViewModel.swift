import Foundation

@Observable
final class AuthViewModel {
    var email = ""
    var password = ""
    var username = ""
    var isSignUp = false
    var isLoading = false
    var errorMessage: String?

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    func submit() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            if isSignUp {
                guard !username.isBlank else {
                    errorMessage = "Username is required."
                    return
                }
                guard username.isValidUsername else {
                    errorMessage = "Username may only contain lowercase letters, numbers, _ - ."
                    return
                }
                try await authService.signUp(email: email, password: password, username: username)
                errorMessage = "Check your email to confirm your account."
            } else {
                try await authService.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
