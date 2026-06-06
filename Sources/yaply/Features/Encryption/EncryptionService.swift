import CryptoKit
import Foundation

// Mirrors packages/crypto/src/encryption.ts.
//
// Wire format (must match web app exactly):
//   encrypted_content = base64( nonce[12] + AES-GCM-ciphertext + GCM-tag[16] )
//
// Key derivation: raw ECDH shared secret → SymmetricKey with NO HKDF.
// Web Crypto's deriveKey(ECDH, {name:'AES-GCM', length:256}) for P-256 uses the raw
// 32-byte shared secret directly as the AES key. CryptoKit must mirror this.
//
// JWK compatibility: the devices table stores public keys as JWK JSON
// (kty:"EC", crv:"P-256", x:base64url, y:base64url). Conversion to/from CryptoKit's
// x963 representation (0x04 prefix + x[32] + y[32]) is handled here.
enum EncryptionService {

    enum Error: Swift.Error {
        case invalidJWK
        case invalidCiphertext
        case decryptionFailed
    }

    // MARK: — Key generation (mirrors generateKeyPair)

    static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    // MARK: — JWK ↔ CryptoKit conversions

    // JWK JSON dict → CryptoKit public key
    // Called when fetching another user's key from `devices.identity_key`
    static func publicKeyFromJWK(_ jwk: [String: String]) throws -> P256.KeyAgreement.PublicKey {
        guard
            let xStr = jwk["x"],
            let yStr = jwk["y"],
            let xData = Data(base64URLEncoded: xStr),
            let yData = Data(base64URLEncoded: yStr),
            xData.count == 32, yData.count == 32
        else { throw Error.invalidJWK }

        var x963 = Data([0x04])  // uncompressed EC point prefix
        x963.append(xData)
        x963.append(yData)
        return try P256.KeyAgreement.PublicKey(x963Representation: x963)
    }

    // CryptoKit public key → JWK JSON dict
    // Called when uploading our own key to `devices.identity_key`
    static func publicKeyToJWK(_ key: P256.KeyAgreement.PublicKey) -> [String: String] {
        let x963 = key.x963Representation  // 65 bytes: [0x04, x[32], y[32]]
        let x = x963[1..<33]
        let y = x963[33..<65]
        return [
            "kty":      "EC",
            "crv":      "P-256",
            "x":        x.base64URLEncodedString(),
            "y":        y.base64URLEncodedString(),
            "key_ops":  "deriveKey",
            "ext":      "true",
        ]
    }

    // MARK: — Shared key derivation (mirrors deriveSharedKey)

    // Both parties independently arrive at the same AES-256 key via ECDH.
    // No HKDF — matches Web Crypto deriveKey behavior for P-256 → AES-GCM-256.
    static func deriveSharedKey(
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        theirPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
        return sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }

    // MARK: — Encrypt (mirrors encryptMessage)

    // Returns base64( nonce[12] + ciphertext + tag[16] )
    // CryptoKit's .combined property emits exactly this layout.
    static func encryptMessage(_ plaintext: String, key: SymmetricKey) throws -> String {
        let data = Data(plaintext.utf8)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw Error.decryptionFailed }
        return combined.base64EncodedString()
    }

    // MARK: — Decrypt (mirrors decryptMessage)

    // Accepts the base64 blob from encrypted_content column.
    // Falls back to plain base64 decode if AES-GCM fails (phase-1 legacy messages).
    static func decryptMessage(_ ciphertextBase64: String, key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: ciphertextBase64) else {
            throw Error.invalidCiphertext
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard let string = String(data: plaintext, encoding: .utf8) else {
            throw Error.decryptionFailed
        }
        return string
    }

    // Fallback for phase-1 messages that are plain base64 (no real encryption)
    static func decryptLegacy(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
