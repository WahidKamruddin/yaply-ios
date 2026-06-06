import CryptoKit
import Foundation

// Mirrors packages/crypto/src/encryption.ts.
//
// Wire format (must match web app exactly):
//   messages.content = base64( AES-GCM ciphertext + GCM-tag[16] )
//   messages.iv      = base64( nonce[12] )
//   iv = nil means phase-1 fallback (content is plain base64 plaintext).
//
// Key derivation: raw ECDH shared secret → SymmetricKey with NO HKDF.
enum EncryptionService {

    enum Error: Swift.Error {
        case invalidJWK
        case invalidCiphertext
        case decryptionFailed
    }

    // MARK: — Key generation

    static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    // MARK: — JWK ↔ CryptoKit conversions

    static func publicKeyFromJWK(_ jwk: [String: String]) throws -> P256.KeyAgreement.PublicKey {
        guard
            let xStr = jwk["x"],
            let yStr = jwk["y"],
            let xData = Data(base64URLEncoded: xStr),
            let yData = Data(base64URLEncoded: yStr),
            xData.count == 32, yData.count == 32
        else { throw Error.invalidJWK }

        var x963 = Data([0x04])
        x963.append(xData)
        x963.append(yData)
        return try P256.KeyAgreement.PublicKey(x963Representation: x963)
    }

    static func publicKeyToJWK(_ key: P256.KeyAgreement.PublicKey) -> [String: String] {
        let x963 = key.x963Representation
        let x = x963[1..<33]
        let y = x963[33..<65]
        return [
            "kty":     "EC",
            "crv":     "P-256",
            "x":       x.base64URLEncodedString(),
            "y":       y.base64URLEncodedString(),
            "key_ops": "deriveKey",
            "ext":     "true",
        ]
    }

    // MARK: — Shared key derivation

    static func deriveSharedKey(
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        theirPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
        return sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    }

    // MARK: — Encrypt

    // Returns (content: base64(ciphertext+tag), iv: base64(nonce[12]))
    static func encryptMessage(_ plaintext: String, key: SymmetricKey) throws -> (content: String, iv: String) {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        let ivData = sealed.nonce.withUnsafeBytes { Data($0) }
        let contentData = sealed.ciphertext + sealed.tag
        return (
            content: contentData.base64EncodedString(),
            iv: ivData.base64EncodedString()
        )
    }

    // MARK: — Decrypt

    // iv=nil means phase-1 fallback (content is plain base64 plaintext).
    static func decryptMessage(content: String, iv: String?, key: SymmetricKey) throws -> String {
        guard let iv else {
            return decryptLegacy(content) ?? content
        }
        guard
            let ivData = Data(base64Encoded: iv),
            let contentData = Data(base64Encoded: content),
            contentData.count > 16
        else { throw Error.invalidCiphertext }

        let nonce = try AES.GCM.Nonce(data: ivData)
        let tag = contentData.suffix(16)
        let ciphertext = contentData.dropLast(16)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard let string = String(data: plaintext, encoding: .utf8) else {
            throw Error.decryptionFailed
        }
        return string
    }

    static func decryptLegacy(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
