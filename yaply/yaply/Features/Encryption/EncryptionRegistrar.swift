import CryptoKit
import Foundation
import Supabase
import PostgREST

// Ensures device/identity-key registration only ever runs once concurrently per
// user. `AuthService` triggers registration from three places (sign-in, session
// restore, and the auth-state-change listener) and `ChatViewModel`/`MessageRepository`
// also need a guaranteed-registered device before encrypting or decrypting — two
// racing registrations on a fresh install would generate two different keypairs
// and desync the published public key from the locally stored private key. All
// callers share one instance so they await the same in-flight task instead of
// racing (mirrors useEncryption.ts's `registrationInFlight` map on web).
actor EncryptionRegistrar {
    static let shared = EncryptionRegistrar()

    private var inFlight: [UUID: Task<Void, Error>] = [:]

    func ensureEncryptionKeys(userId: UUID) async throws {
        if let existing = inFlight[userId] {
            try await existing.value
            return
        }
        let task = Task { try await Self.register(userId: userId) }
        inFlight[userId] = task
        defer { inFlight[userId] = nil }
        try await task.value
    }

    private static func register(userId: UUID) async throws {
        var storedDeviceId = try KeyStore.loadDeviceId(forUser: userId)

        // Orphan check — MANDATORY. A locally stored device_id with no matching
        // row means this install was revoked from another device (while offline,
        // or after its access token expired). Re-registering the same keypair
        // would silently undo the revocation, so wipe every local key first: the
        // install comes back as a brand-new device and has to be paired again to
        // see history. A *failed* lookup must never be read as "revoked" — only
        // a successful empty result counts, or a network blip would wipe keys.
        if let existingId = storedDeviceId {
            if try await deviceRowIsMissing(userId: userId, deviceId: existingId) {
                print("[EncryptionRegistrar] device was revoked — clearing local keys")
                KeyStore.clearAllKeys()
                storedDeviceId = nil
            }
        }

        let privateKey: P256.KeyAgreement.PrivateKey
        if storedDeviceId != nil, let existing = try KeyStore.loadIdentityKeyPair() {
            privateKey = existing
        } else {
            privateKey = EncryptionService.generateKeyPair()
            try KeyStore.storeIdentityKeyPair(privateKey)
        }

        let isNewDevice = storedDeviceId == nil
        let deviceId: Int
        if let existing = storedDeviceId {
            deviceId = existing
        } else {
            // Random 31-bit id, matching web's per-install random device_id — never
            // hardcode 1, which was the single-slot bug this scheme replaces.
            deviceId = Int.random(in: 1...Int(Int32.max))
            try KeyStore.storeDeviceId(deviceId, forUser: userId)
        }

        let (jwk, fingerprint) = EncryptionService.publicKeyToJWKWithFingerprint(privateKey.publicKey)
        let params = UpsertDeviceParams(
            userId: userId,
            deviceId: deviceId,
            identityKey: jwk,
            keyFingerprint: fingerprint,
            lastActiveAt: ISO8601DateFormatter().string(from: Date()),
            sessionId: await currentSessionId(),
            platform: DeviceName.platform,
            deviceName: isNewDevice ? await DeviceName.generate() : nil
        )

        try await supabase
            .from("devices")
            .upsert(params, onConflict: "user_id,device_id")
            .execute()
    }

    // True only when the query SUCCEEDS and returns nothing. Any thrown error
    // (offline, transient failure) returns false so the caller leaves the keys
    // alone.
    private static func deviceRowIsMissing(userId: UUID, deviceId: Int) async -> Bool {
        struct IdRow: Decodable { let id: UUID }
        do {
            let rows: [IdRow] = try await supabase
                .from("devices")
                .select("id")
                .eq("user_id", value: userId.uuidString)
                .eq("device_id", value: String(deviceId))
                .execute()
                .value
            return rows.isEmpty
        } catch {
            return false
        }
    }

    // The `session_id` claim of the current access token. Best-effort: a token
    // without the claim just leaves the column null, which means revoking that
    // device can drop its row but not kill its session.
    private static func currentSessionId() async -> String? {
        guard let session = try? await supabase.auth.session else { return nil }
        let parts = session.accessToken.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        struct Claims: Decodable { let session_id: String? }
        return try? JSONDecoder().decode(Claims.self, from: payload).session_id
    }
}
