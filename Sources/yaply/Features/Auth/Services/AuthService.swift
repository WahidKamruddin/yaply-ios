import Supabase
import Foundation

// Mirrors src/lib/auth.ts.
// Manages Supabase session lifecycle and triggers encryption key init on login.
@Observable
final class AuthService {
    private(set) var currentUser: User?
    private(set) var isLoading = true

    init() {
        Task { await startAuthListener() }
    }

    // MARK: — Public API

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        currentUser = session.user
        await initEncryptionKeys(userId: session.user.id)
    }

    func signUp(email: String, password: String, username: String) async throws {
        try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["username": .string(username)]
        )
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        KeyStore.clearAllKeys()
        currentUser = nil
    }

    // MARK: — Session restore + auth state listener

    private func startAuthListener() async {
        // Restore existing session immediately
        if let session = try? await supabase.auth.session {
            currentUser = session.user
            await initEncryptionKeys(userId: session.user.id)
        }
        isLoading = false

        // Stream all future auth state changes
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .signedIn:
                currentUser = session?.user
                if let user = session?.user {
                    await initEncryptionKeys(userId: user.id)
                }
            case .signedOut:
                currentUser = nil
                KeyStore.clearAllKeys()
            default:
                break
            }
        }
    }

    // MARK: — Encryption init on login (mirrors useEncryption's initKeys)

    // Generates an ECDH P-256 keypair on first login and upserts the public key
    // to the `devices` table (device_id = 1) so other users can derive shared keys.
    private func initEncryptionKeys(userId: UUID) async {
        do {
            let privateKey: P256.KeyAgreement.PrivateKey

            if let existing = try KeyStore.loadIdentityKeyPair() {
                privateKey = existing
            } else {
                privateKey = EncryptionService.generateKeyPair()
                try KeyStore.storeIdentityKeyPair(privateKey)
            }

            let jwk = EncryptionService.publicKeyToJWK(privateKey.publicKey)
            let params = UpsertDeviceParams(userId: userId, deviceId: 1, identityKey: jwk)

            try await supabase
                .from("devices")
                .upsert(params, onConflict: "user_id,device_id")
                .execute()

        } catch {
            // Non-fatal — app works without encryption, falls back to base64
            print("[AuthService] Encryption init failed: \(error)")
        }
    }
}
