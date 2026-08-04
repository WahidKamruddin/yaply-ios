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

        guard let usersWithAnyDevice = try? await repository.fetchUserIdsWithAnyDevice(userIds: memberUserIds),
              memberUserIds.allSatisfy({ usersWithAnyDevice.contains($0) })
        else { return nil }

        guard let devices = try? await repository.fetchActiveDeviceRows(userIds: memberUserIds) else { return nil }

        let mk = EncryptionService.generateMessageKey()
        guard let sealed = try? EncryptionService.encryptMessage(plaintext, key: mk) else { return nil }

        // One ephemeral P-256 keypair for the whole message, shared across every
        // recipient device's envelope, per the documented wire-format contract.
        let ephemeral = P256.KeyAgreement.PrivateKey()

        var envelopes: [EnvelopePayload] = []
        for device in devices {
            guard
                let coords = device.identityKey,
                let fp = device.keyFingerprint,
                let pubKey = try? EncryptionService.publicKeyFromJWK(["x": coords.x, "y": coords.y]),
                let wrapped = try? EncryptionService.wrapKey(mk, for: pubKey, using: ephemeral)
            else { continue }
            envelopes.append(EnvelopePayload(
                recipientUserId: device.userId,
                recipientFp: fp,
                ephPub: EncryptionService.jwkToJSONString(wrapped.ephPubJWK),
                keyIv: wrapped.keyIv,
                wrappedKey: wrapped.wrappedKey
            ))
        }
        guard !envelopes.isEmpty else { return nil }
        return (sealed.content, sealed.iv, envelopes)
    }

    // Decrypts an enc_v=2 message for this device: fetches the envelope matching
    // `myFingerprint`, unwraps the message key, then decrypts `content`. Returns
    // nil on ANY failure (no envelope, bad wrap, bad content) — callers must treat
    // nil as a permanent, honest decrypt failure and never fall back to another
    // decode path.
    static func decryptV2(
        messageId: UUID,
        content: String,
        iv: String,
        repository: MessageRepository,
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        myFingerprint: String
    ) async -> String? {
        guard let envelope = try? await repository.fetchEnvelope(messageId: messageId, recipientFp: myFingerprint) else {
            return nil
        }
        guard
            let ephPubJWK = try? EncryptionService.jwkFromJSONString(envelope.ephPub),
            let mk = try? EncryptionService.unwrapKey(
                ephPubJWK: ephPubJWK,
                keyIv: envelope.keyIv,
                wrappedKey: envelope.wrappedKey,
                myPrivateKey: myPrivateKey
            ),
            let plaintext = try? EncryptionService.decryptMessage(content: content, iv: iv, key: mk)
        else { return nil }
        return plaintext
    }
}
