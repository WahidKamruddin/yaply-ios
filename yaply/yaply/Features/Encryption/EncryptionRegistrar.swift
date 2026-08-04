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
        let privateKey: P256.KeyAgreement.PrivateKey
        if let existing = try KeyStore.loadIdentityKeyPair() {
            privateKey = existing
        } else {
            privateKey = EncryptionService.generateKeyPair()
            try KeyStore.storeIdentityKeyPair(privateKey)
        }

        let deviceId: Int
        if let existing = try KeyStore.loadDeviceId(forUser: userId) {
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
            lastActiveAt: ISO8601DateFormatter().string(from: Date())
        )

        try await supabase
            .from("devices")
            .upsert(params, onConflict: "user_id,device_id")
            .execute()
    }
}
