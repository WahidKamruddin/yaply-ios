import Foundation

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Validates username format: lowercase alphanumeric + _ - .  (mirrors profiles_username_format constraint)
    var isValidUsername: Bool {
        !isBlank && range(of: "^[a-z0-9_.\\-]+$", options: .regularExpression) != nil
    }
}
