import Foundation

// Mirrors src/lib/passwordStrength.ts exactly — same five checks, same
// strength thresholds — so a password accepted/rejected on iOS is accepted/
// rejected identically on web.
struct PasswordCheck: Identifiable {
    let key: String
    let label: String
    let met: Bool
    var id: String { key }
}

enum PasswordStrengthLevel: String {
    case weak, fair, good, strong
}

enum PasswordStrength {
    private static let minLength = 8

    static func checks(for password: String) -> [PasswordCheck] {
        [
            PasswordCheck(key: "length", label: "At least 8 characters", met: password.count >= minLength),
            PasswordCheck(key: "upper", label: "An uppercase letter", met: password.range(of: "[A-Z]", options: .regularExpression) != nil),
            PasswordCheck(key: "lower", label: "A lowercase letter", met: password.range(of: "[a-z]", options: .regularExpression) != nil),
            PasswordCheck(key: "number", label: "A number", met: password.range(of: "[0-9]", options: .regularExpression) != nil),
            PasswordCheck(key: "symbol", label: "A symbol (!@#$…)", met: password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil),
        ]
    }

    // All five checks must pass for a password to be accepted on signup.
    static func isStrongEnough(_ password: String) -> Bool {
        checks(for: password).allSatisfy(\.met)
    }

    static func level(for password: String) -> PasswordStrengthLevel {
        guard !password.isEmpty else { return .weak }
        let metCount = checks(for: password).filter(\.met).count
        switch metCount {
        case 0...2: return .weak
        case 3: return .fair
        case 4: return .good
        default: return .strong
        }
    }
}
