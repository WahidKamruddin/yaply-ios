import Foundation

// Mirrors the `devices` table. identity_key is JWK JSON stored as a dictionary.
// Used by EncryptionService to exchange public keys between participants.
//
// v2: one row per install — deviceId is a random per-install id (never hardcoded
// to 1, which was the single-slot bug the envelope scheme replaces). keyFingerprint
// is the JWK `x.y` used to address envelopes to this exact device.
struct DeviceRow: Codable {
    let userId: UUID
    let deviceId: Int
    // identity_key decoded as JWKCoords — web JWKs include ext:Bool and key_ops:[String]
    // which break [String:String]; we only need x and y for key derivation.
    var identityKey: JWKCoords?
    var keyFingerprint: String?
    var lastActiveAt: Date?

    struct JWKCoords: Codable {
        let x: String
        let y: String
    }

    enum CodingKeys: String, CodingKey {
        case userId         = "user_id"
        case deviceId       = "device_id"
        case identityKey    = "identity_key"
        case keyFingerprint = "key_fingerprint"
        case lastActiveAt   = "last_active_at"
    }
}

struct UpsertDeviceParams: Encodable {
    let userId: UUID
    let deviceId: Int
    let identityKey: [String: String]
    let keyFingerprint: String
    let lastActiveAt: String
    // The auth session this install signed in with, from the access token's
    // `session_id` claim. Recorded so `revoke_device` can kill that session —
    // without it, revoking can delete the row but not sign the device out.
    let sessionId: String?
    let platform: String
    // Only sent on FIRST registration. Including it on every login would
    // overwrite a name the user chose in Settings.
    let deviceName: String?

    enum CodingKeys: String, CodingKey {
        case userId         = "user_id"
        case deviceId       = "device_id"
        case identityKey    = "identity_key"
        case keyFingerprint = "key_fingerprint"
        case lastActiveAt   = "last_active_at"
        case sessionId      = "session_id"
        case platform
        case deviceName     = "device_name"
    }

    // device_name is omitted entirely (not sent as null) when nil, so an upsert
    // on an existing row leaves the stored name untouched.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userId, forKey: .userId)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(identityKey, forKey: .identityKey)
        try c.encode(keyFingerprint, forKey: .keyFingerprint)
        try c.encode(lastActiveAt, forKey: .lastActiveAt)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(platform, forKey: .platform)
        try c.encodeIfPresent(deviceName, forKey: .deviceName)
    }
}

// A row as shown in Settings → Devices. Separate from DeviceRow (which exists
// for the encryption path and only carries what key wrapping needs).
struct ManagedDevice: Codable, Identifiable, Hashable {
    let id: UUID
    let deviceId: Int
    var deviceName: String?
    let platform: String?
    let keyFingerprint: String?
    let lastActiveAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId       = "device_id"
        case deviceName     = "device_name"
        case platform
        case keyFingerprint = "key_fingerprint"
        case lastActiveAt   = "last_active_at"
    }

    var displayName: String {
        if let name = deviceName, !name.isEmpty { return name }
        return "Device \(deviceId)"
    }
}

// Mirrors the `message_envelopes` table — one row per recipient device per message.
// wrapped_key = base64(AES-GCM(KEK, raw 32-byte message key) + tag[16]); KEK is the
// raw ECDH shared secret between the message's ephemeral keypair and the recipient
// device's identity key (no HKDF), matching EncryptionService's key-derivation rule.
struct MessageEnvelope: Codable {
    var messageId: UUID?
    let recipientUserId: UUID
    let recipientFp: String
    let ephPub: String
    let keyIv: String
    let wrappedKey: String

    enum CodingKeys: String, CodingKey {
        case messageId      = "message_id"
        case recipientUserId = "recipient_user_id"
        case recipientFp    = "recipient_fp"
        case ephPub         = "eph_pub"
        case keyIv          = "key_iv"
        case wrappedKey     = "wrapped_key"
    }
}

// One element of the `p_envelopes` jsonb array passed to `send_message_with_envelopes`.
struct EnvelopePayload: Encodable {
    let recipientUserId: UUID
    let recipientFp: String
    let ephPub: String
    let keyIv: String
    let wrappedKey: String

    enum CodingKeys: String, CodingKey {
        case recipientUserId = "recipient_user_id"
        case recipientFp     = "recipient_fp"
        case ephPub          = "eph_pub"
        case keyIv           = "key_iv"
        case wrappedKey      = "wrapped_key"
    }
}

// Params for the `send_message_with_envelopes` RPC — the only way to insert an
// enc_v=2 message; it writes the message row and every envelope row atomically
// and rejects an empty envelope array or a NULL iv.
struct SendMessageWithEnvelopesParams: Encodable {
    let pConversationId: UUID
    let pContent: String
    let pIv: String
    let pEnvelopes: [EnvelopePayload]
    let pType: String
    let pReplyToId: UUID?
    let pThreadId: UUID?
    let pMediaUrl: String?
    let pMediaMime: String?

    enum CodingKeys: String, CodingKey {
        case pConversationId = "p_conversation_id"
        case pContent        = "p_content"
        case pIv             = "p_iv"
        case pEnvelopes      = "p_envelopes"
        case pType           = "p_type"
        case pReplyToId      = "p_reply_to_id"
        case pThreadId       = "p_thread_id"
        case pMediaUrl       = "p_media_url"
        case pMediaMime      = "p_media_mime"
    }
}
