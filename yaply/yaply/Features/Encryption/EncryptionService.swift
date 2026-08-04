import CryptoKit
import Foundation

// Mirrors packages/crypto/src/encryption.ts.
//
// Wire format v2 (must match web app exactly — see ../../../CLAUDE.md):
//   messages.content = base64( AES-GCM(message key, plaintext) ciphertext + tag[16] )
//   messages.iv      = base64( nonce[12] )
//   messages.enc_v   = 2  (envelopes exist)  |  nil = phase-1 (iv also nil, content plain base64)
//   One `message_envelopes` row per recipient device wraps the per-message key:
//     eph_pub    = JWK of a fresh P-256 keypair generated for this message
//     KEK        = raw ECDH(eph_priv, recipient device pub) — NO HKDF
//     wrapped_key = base64( AES-GCM(KEK, raw 32-byte message key) + tag[16] )
//     key_iv     = base64( nonce[12] ) for that wrap
//
// Key derivation throughout this file: raw ECDH shared secret → SymmetricKey, never HKDF.
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

    // MARK: — v2 envelope encryption (per-message key wrapped per recipient device)

    // JWK `x.y` fingerprint — matches `devices.key_fingerprint` / `message_envelopes.recipient_fp`.
    static func fingerprint(for key: P256.KeyAgreement.PublicKey) -> String {
        let jwk = publicKeyToJWK(key)
        return "\(jwk["x"] ?? "").\(jwk["y"] ?? "")"
    }

    static func publicKeyToJWKWithFingerprint(_ key: P256.KeyAgreement.PublicKey) -> (jwk: [String: String], fingerprint: String) {
        (publicKeyToJWK(key), fingerprint(for: key))
    }

    // Fresh random 256-bit message key (mk), one per message.
    static func generateMessageKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // Wraps `mk` for one recipient device using `ephemeral` — the SAME ephemeral
    // P-256 keypair the caller generated once for this whole message (per the wire
    // format: "one ephemeral P-256 keypair per message"), not a new one per call.
    // Raw ECDH shared secret with the recipient's identity key is the KEK (no HKDF),
    // then AES-GCM(KEK, raw mk). Returns the pieces of one `message_envelopes` row.
    static func wrapKey(
        _ mk: SymmetricKey,
        for recipientPublicKey: P256.KeyAgreement.PublicKey,
        using ephemeral: P256.KeyAgreement.PrivateKey
    ) throws -> (ephPubJWK: [String: String], keyIv: String, wrappedKey: String) {
        let kek = try deriveSharedKey(myPrivateKey: ephemeral, theirPublicKey: recipientPublicKey)
        let mkData = mk.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(mkData, using: kek)
        let ivData = sealed.nonce.withUnsafeBytes { Data($0) }
        let wrapped = sealed.ciphertext + sealed.tag
        return (
            ephPubJWK: publicKeyToJWK(ephemeral.publicKey),
            keyIv: ivData.base64EncodedString(),
            wrappedKey: wrapped.base64EncodedString()
        )
    }

    // `eph_pub` on the wire is a JSON-stringified JWK (matches web), not a raw dict.
    static func jwkToJSONString(_ jwk: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(jwk), let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // Real Web Crypto JWK output includes non-string fields (`ext: Bool`,
    // `key_ops: [String]`), which break a blanket [String:String] decode —
    // decode only the x/y coordinates we actually need, same tolerance as
    // publicKeyFromJWK/DeviceRow.JWKCoords elsewhere in this file/codebase.
    static func jwkFromJSONString(_ json: String) throws -> [String: String] {
        struct Coords: Decodable { let x: String; let y: String }
        guard let data = json.data(using: .utf8) else { throw Error.invalidJWK }
        let coords = try JSONDecoder().decode(Coords.self, from: data)
        return ["x": coords.x, "y": coords.y]
    }

    // Unwraps `mk` from an envelope addressed to this device: the same KEK is
    // recovered via raw ECDH between our identity private key and the message's
    // ephemeral public key.
    static func unwrapKey(
        ephPubJWK: [String: String],
        keyIv: String,
        wrappedKey: String,
        myPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> SymmetricKey {
        let ephPubKey = try publicKeyFromJWK(ephPubJWK)
        let kek = try deriveSharedKey(myPrivateKey: myPrivateKey, theirPublicKey: ephPubKey)
        guard
            let ivData = Data(base64Encoded: keyIv),
            let wrappedData = Data(base64Encoded: wrappedKey),
            wrappedData.count > 16
        else { throw Error.invalidCiphertext }
        let nonce = try AES.GCM.Nonce(data: ivData)
        let tag = wrappedData.suffix(16)
        let ciphertext = wrappedData.dropLast(16)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let mkData = try AES.GCM.open(sealedBox, using: kek)
        return SymmetricKey(data: mkData)
    }
}
