import Supabase
import Foundation
import Supabase
import Auth
import PostgREST
import CryptoKit

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
        await ensureEncryptionKeys(userId: session.user.id)
    }

    // Drives an ASWebAuthenticationSession internally (supabase-swift's
    // signInWithOAuth) and exchanges the redirect for a session — the
    // yaply://login-callback scheme is registered in Info.plist and must be
    // added to the Supabase Dashboard's OAuth redirect URL allow-list.
    func signInWithGoogle() async throws {
        let session = try await supabase.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "yaply://login-callback")!
        )
        currentUser = session.user
        await ensureEncryptionKeys(userId: session.user.id)
    }

    // No username collected at signup — mirrors web: the handle_new_user()
    // Postgres trigger seeds a placeholder username from the email and sets
    // username_set = false, which the client prompts to replace on first
    // login (see UsernameSetupView).
    func signUp(email: String, password: String) async throws {
        try await supabase.auth.signUp(email: email, password: password)
    }

    func resendConfirmationEmail(email: String) async throws {
        try await supabase.auth.resend(email: email, type: .signup)
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
            await ensureEncryptionKeys(userId: session.user.id)
        }
        isLoading = false

        // Stream all future auth state changes
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .signedIn:
                currentUser = session?.user
                if let user = session?.user {
                    await ensureEncryptionKeys(userId: user.id)
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

    // Generates (or loads) this install's identity keypair + device_id and upserts
    // the v2 device row (identity_key, key_fingerprint) so other users' devices can
    // wrap message keys to it. Routed through EncryptionRegistrar.shared so the
    // three call sites above (signIn, restore, auth-state listener) can never race
    // each other into generating two different keypairs on a fresh install.
    private func ensureEncryptionKeys(userId: UUID) async {
        do {
            try await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: userId)
        } catch {
            // Non-fatal — app works without encryption, falls back to base64
            print("[AuthService] Encryption init failed: \(error)")
        }
    }
}
