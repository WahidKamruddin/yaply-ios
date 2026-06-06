import Foundation

// Mirrors the `devices` table. identity_key is JWK JSON stored as a dictionary.
// Used by EncryptionService to exchange public keys between participants.
struct DeviceRow: Codable {
    let userId: UUID
    let deviceId: Int
    // identity_key decoded as JWKCoords — web JWKs include ext:Bool and key_ops:[String]
    // which break [String:String]; we only need x and y for key derivation.
    var identityKey: JWKCoords?

    struct JWKCoords: Codable {
        let x: String
        let y: String
    }

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
