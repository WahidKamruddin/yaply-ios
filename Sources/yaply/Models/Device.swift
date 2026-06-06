import Foundation

// Mirrors the `devices` table. identity_key is JWK JSON stored as a dictionary.
// Used by EncryptionService to exchange public keys between participants.
struct DeviceRow: Codable {
    let userId: UUID
    let deviceId: Int
    var identityKey: [String: String]?

    enum CodingKeys: String, CodingKey {
        case userId     = "user_id"
        case deviceId   = "device_id"
        case identityKey = "identity_key"
    }
}

struct UpsertDeviceParams: Encodable {
    let userId: UUID
    let deviceId: Int
    let identityKey: [String: String]

    enum CodingKeys: String, CodingKey {
        case userId     = "user_id"
        case deviceId   = "device_id"
        case identityKey = "identity_key"
    }
}
