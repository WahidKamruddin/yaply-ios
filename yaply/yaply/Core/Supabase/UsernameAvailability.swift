import Supabase
import Foundation

// Mirrors src/features/chat/hooks/useUsernameAvailability.ts — the
// `profiles.username` unique constraint is the actual source of truth, this
// lets the UI block Save before a write is even attempted rather than only
// reacting to a Postgres 23505 error after a failed insert/update.
enum UsernameAvailability: Equatable {
    case idle
    case checking
    case available
    case taken
    case invalid
}

enum UsernameAvailabilityChecker {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isFormatValid(_ candidate: String) -> Bool {
        candidate.count >= 3 && candidate.isValidUsername
    }

    /// `excluding` should be the caller's own user id when editing an existing
    /// profile, so re-saving your own unchanged username doesn't read as taken.
    static func isAvailable(_ candidate: String, excluding userId: UUID?) async throws -> Bool {
        struct Row: Decodable { let id: UUID }
        var query = supabase.from("profiles").select("id").eq("username", value: candidate)
        if let userId {
            query = query.neq("id", value: userId.uuidString)
        }
        let rows: [Row] = try await query.execute().value
        return rows.isEmpty
    }
}
