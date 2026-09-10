import Foundation

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var username: String
    var displayName: String?
    var avatarUrl: String?
    var bio: String?
    var isOnline: Bool
    var lastSeenAt: Date?
    let createdAt: Date
    var updatedAt: Date
    // Raw "YYYY-MM-DD" string from the `date`-typed `birthdate` column — decoded
    // as a plain string since PostgREST's default decoder doesn't parse bare
    // dates the same way as timestamptz columns. Use `birthdate` below instead
    // of this field directly.
    var birthdateRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, username, bio
        case displayName  = "display_name"
        case avatarUrl    = "avatar_url"
        case isOnline     = "is_online"
        case lastSeenAt   = "last_seen_at"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
        case birthdateRaw = "birthdate"
    }

    private static let birthdateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var birthdate: Date? {
        get { birthdateRaw.flatMap { Self.birthdateFormatter.date(from: $0) } }
        set { birthdateRaw = newValue.map { Self.birthdateFormatter.string(from: $0) } }
    }

    // Display name with username fallback
    var name: String { displayName ?? username }

    var initials: String {
        let n = name
        return String(n.prefix(1)).uppercased()
    }
}
