import Foundation
import Supabase

// Mirrors src/features/chat/components/UsernameSetupModal.tsx: neither
// signup path (email/password or Google) collects a real username anymore —
// the handle_new_user() Postgres trigger seeds a placeholder from the email
// local-part and sets profiles.username_set = false. The client checks that
// flag right after login and blocks on this modal until a real, validated
// username is chosen.
@Observable
final class UsernameSetupViewModel {
    var username: String
    private(set) var availability: UsernameAvailability = .idle
    private(set) var isSaving = false
    var error: String?

    private var checkTask: Task<Void, Never>?
    private let userId: UUID

    init(userId: UUID, suggestedUsername: String) {
        self.userId = userId
        self.username = suggestedUsername
    }

    private struct UsernameSetupRow: Decodable {
        let username: String
        let usernameSet: Bool
        enum CodingKeys: String, CodingKey {
            case username
            case usernameSet = "username_set"
        }
    }

    /// Checks whether the given user still needs to pick a real username.
    /// Returns nil on any fetch failure (fails open — never blocks login on
    /// a transient network error).
    static func needsSetup(userId: UUID) async -> String? {
        guard let row: UsernameSetupRow = try? await supabase
            .from("profiles")
            .select("username, username_set")
            .eq("id", value: userId.uuidString)
            .single()
            .execute()
            .value
        else { return nil }
        return row.usernameSet ? nil : row.username
    }

    func checkAvailability() {
        checkTask?.cancel()
        let candidate = UsernameAvailabilityChecker.normalize(username)

        guard !candidate.isEmpty else {
            availability = .idle
            return
        }
        guard UsernameAvailabilityChecker.isFormatValid(candidate) else {
            availability = .invalid
            return
        }

        availability = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                // Exclude our own row — the seeded placeholder is technically
                // "taken" by us, and re-submitting it unchanged should read
                // as available.
                let available = try await UsernameAvailabilityChecker.isAvailable(candidate, excluding: userId)
                guard !Task.isCancelled else { return }
                availability = available ? .available : .taken
            } catch {
                guard !Task.isCancelled else { return }
                availability = .idle
            }
        }
    }

    func save() async -> Bool {
        error = nil
        guard availability != .invalid else {
            error = "Username must be at least 3 characters, using only lowercase letters, numbers, underscores, dots, and hyphens."
            return false
        }
        guard availability == .available else {
            error = "That username is taken."
            return false
        }

        isSaving = true
        defer { isSaving = false }

        struct Update: Encodable {
            let username: String
            let username_set: Bool
            let updated_at: String
        }

        let candidate = UsernameAvailabilityChecker.normalize(username)
        do {
            try await supabase
                .from("profiles")
                .update(Update(username: candidate, username_set: true, updated_at: Date().iso8601))
                .eq("id", value: userId.uuidString)
                .execute()
            return true
        } catch {
            let message = error.localizedDescription
            self.error = message.contains("23505") ? "That username is taken." : message
            return false
        }
    }
}
