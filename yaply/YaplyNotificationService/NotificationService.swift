import UserNotifications

// Rewrites a push notification's body with the decrypted message text.
//
// The server only ever holds ciphertext, so the payload carries the sealed
// content plus the one envelope this device can open, and the decryption
// happens here — the same unwrap-then-open path ChatViewModel uses, minus the
// network fetch, because the envelope arrives in the payload.
//
// Every failure path delivers the unmodified content, whose body the server
// pre-filled with a safe placeholder. Never surface ciphertext or a decode
// artifact to the user.
final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = mutableContent

        guard let plaintext = decryptBody(from: request.content.userInfo) else {
            contentHandler(mutableContent)
            return
        }

        mutableContent.body = plaintext
        contentHandler(mutableContent)
    }

    // iOS gives the extension roughly 30 seconds. Deliver whatever we have.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    private func decryptBody(from info: [AnyHashable: Any]) -> String? {
        // Media messages are not encrypted and the server already wrote their
        // body; an oversized message sets needs_fetch and has no content here.
        guard info["decryptable"] as? Bool == true else { return nil }
        guard let content = info["content"] as? String else { return nil }

        let iv = info["iv"] as? String

        // Branch on enc_v first, then iv — the same order as every other
        // decrypt site in the app.
        switch info["enc_v"] as? Int {
        case 2:
            guard
                let iv,
                let envelope = info["envelope"] as? [String: Any],
                let fingerprint = envelope["recipient_fp"] as? String,
                let ephPub = envelope["eph_pub"] as? String,
                let keyIv = envelope["key_iv"] as? String,
                let wrappedKey = envelope["wrapped_key"] as? String,
                let recipientId = (info["recipient_id"] as? String).flatMap(UUID.init(uuidString:)),
                let privateKey = KeyStore.privateKey(forFingerprint: fingerprint, userId: recipientId),
                let ephPubJWK = try? EncryptionService.jwkFromJSONString(ephPub),
                let messageKey = try? EncryptionService.unwrapKey(
                    ephPubJWK: ephPubJWK,
                    keyIv: keyIv,
                    wrappedKey: wrappedKey,
                    myPrivateKey: privateKey
                )
            else { return nil }
            return try? EncryptionService.decryptMessage(content: content, iv: iv, key: messageKey)

        case nil where iv == nil:
            // Phase-1: content is plain base64 UTF-8, no envelope involved.
            return EncryptionService.decryptLegacy(content)

        default:
            return nil
        }
    }
}
