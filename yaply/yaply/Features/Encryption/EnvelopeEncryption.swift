import CryptoKit
import Foundation

// Shared v2 envelope send/decrypt logic used by both ChatViewModel and
// ThreadViewModel so the recipient-set/wrap loop isn't duplicated between them.
enum EnvelopeEncryption {

    // Seals `plaintext` once and wraps a fresh per-message key for every active
    // device of every id in `memberUserIds` — callers MUST include the sender's
    // own id, or the sender's other devices (and this one, on reload) can't read
    // the message back. Returns nil to signal the phase-1 fallback: at least one
    // member has literally zero registered devices (ever), so a permanently-
    // undecryptable v2 message would be handed to them. A member whose only
    // device is merely stale (>90 days inactive) does NOT trigger this — that
    // device is simply excluded from the envelope list below.
    static func encryptForMembers(
        plaintext: String,
        memberUserIds: [UUID],
        repository: MessageRepository
    ) async -> (content: String, iv: String, envelopes: [EnvelopePayload])? {
        guard !memberUserIds.isEmpty else { return nil }

        // One cached lookup for both checks — this used to be two sequential
        // `devices` queries on every send, ahead of the RPC itself.
        guard let byUser = try? await DeviceListCache.devices(for: memberUserIds, repository: repository),
              memberUserIds.allSatisfy({ !(byUser[$0] ?? []).isEmpty })
        else { return nil }

        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        let devices = byUser.values.joined().filter { ($0.lastActiveAt ?? .distantPast) > cutoff }

        let recipients: [SealRecipient] = devices.compactMap { device in
            guard let coords = device.identityKey, let fp = device.keyFingerprint else { return nil }
            return SealRecipient(userId: device.userId, fp: fp, x: coords.x, y: coords.y)
        }
        // The seal and the per-device ECDH wraps are pure CPU. Off the main
        // actor so they can't stall the UI — a send starts right as the
        // composer → bubble flight animates, which is drawn on the main thread.
        guard let sealed = await Task.detached(priority: .userInitiated, operation: {
            seal(plaintext: plaintext, recipients: recipients)
        }).value else { return nil }

        let envelopes = sealed.wrapped.map {
            EnvelopePayload(
                recipientUserId: $0.userId, recipientFp: $0.fp,
                ephPub: $0.ephPub, keyIv: $0.keyIv, wrappedKey: $0.wrappedKey
            )
        }
        guard !envelopes.isEmpty else { return nil }
        return (sealed.content, sealed.iv, envelopes)
    }

    nonisolated struct SealRecipient: Sendable {
        let userId: UUID
        let fp: String
        let x: String
        let y: String
    }

    nonisolated struct SealedEnvelope: Sendable {
        let userId: UUID
        let fp: String
        let ephPub: String
        let keyIv: String
        let wrappedKey: String
    }

    /// The pure crypto half of `encryptForMembers`: seals `plaintext` once under
    /// a fresh message key and wraps that key for each recipient device.
    nonisolated private static func seal(
        plaintext: String,
        recipients: [SealRecipient]
    ) -> (content: String, iv: String, wrapped: [SealedEnvelope])? {
        let mk = EncryptionService.generateMessageKey()
        guard let sealed = try? EncryptionService.encryptMessage(plaintext, key: mk) else { return nil }

        // One ephemeral P-256 keypair for the whole message, shared across every
        // recipient device's envelope, per the documented wire-format contract.
        let ephemeral = P256.KeyAgreement.PrivateKey()

        var wrapped: [SealedEnvelope] = []
        for recipient in recipients {
            guard
                let pubKey = try? EncryptionService.publicKeyFromJWK(["x": recipient.x, "y": recipient.y]),
                let w = try? EncryptionService.wrapKey(mk, for: pubKey, using: ephemeral)
            else { continue }
            wrapped.append(SealedEnvelope(
                userId: recipient.userId,
                fp: recipient.fp,
                ephPub: EncryptionService.jwkToJSONString(w.ephPubJWK),
                keyIv: w.keyIv,
                wrappedKey: w.wrappedKey
            ))
        }
        return (sealed.content, sealed.iv, wrapped)
    }

    // Decrypts an enc_v=2 message for this install: fetches an envelope sealed to
    // any of this device's candidate fingerprints (its own key, or one adopted
    // via live pairing), unwraps the message key with whichever private key that
    // envelope names, then decrypts `content`. Returns nil on ANY failure (no
    // envelope, bad wrap, bad content) — callers must treat nil as a permanent,
    // honest decrypt failure and never fall back to another decode path.
    static func decryptV2(
        messageId: UUID,
        content: String,
        iv: String,
        repository: MessageRepository,
        userId: UUID
    ) async -> String? {
        let candidates = KeyStore.candidateFingerprints(forUser: userId)
        // `try?` on an optional-returning throwing call flattens to one level,
        // so this single binding covers both "query failed" and "no envelope".
        guard let envelope = try? await repository.fetchEnvelope(messageId: messageId, candidateFps: candidates)
        else { return nil }
        return open(envelope: envelope, content: content, iv: iv, userId: userId)
    }

    // Same unwrap, but against an envelope that has already been fetched —
    // used when a whole page's envelopes were pulled in one query instead of
    // one round-trip per message. Identical failure semantics: nil means a
    // permanent, honest decrypt failure, never a fall-through to another path.
    static func open(
        envelope: MessageEnvelope,
        content: String,
        iv: String,
        userId: UUID
    ) -> String? {
        // The envelope names the fingerprint it was sealed to, which may be this
        // install's own device key or an escrowed one — pick the matching private
        // key rather than assuming the own pair.
        guard let privateKey = KeyStore.privateKey(forFingerprint: envelope.recipientFp, userId: userId) else {
            return nil
        }
        return unwrap(envelope: envelope, content: content, iv: iv, privateKey: privateKey)
    }

    /// The pure crypto half of `open`, with the private key already resolved —
    /// safe off the main actor, so a page's worth of ECDH unwraps can run in the
    /// background. Same failure semantics: nil is a permanent, honest failure.
    nonisolated static func unwrap(
        envelope: MessageEnvelope,
        content: String,
        iv: String,
        privateKey: P256.KeyAgreement.PrivateKey
    ) -> String? {
        guard
            let ephPubJWK = try? EncryptionService.jwkFromJSONString(envelope.ephPub),
            let mk = try? EncryptionService.unwrapKey(
                ephPubJWK: ephPubJWK,
                keyIv: envelope.keyIv,
                wrappedKey: envelope.wrappedKey,
                myPrivateKey: privateKey
            ),
            let plaintext = try? EncryptionService.decryptMessage(content: content, iv: iv, key: mk)
        else { return nil }
        return plaintext
    }
}
