import CryptoKit
import Foundation

// Mirrors packages/crypto/src/pairing.ts. Every constant here is part of a
// cross-platform contract — if any of it drifts, the two devices derive
// different secrets and the user is correctly told the codes don't match.
//
// Live pairing transfers identity key material from an already-linked device
// (the *sender*) to a newly signed-in one (the *receiver*) over an ephemeral
// private Realtime channel. Nothing is stored server-side.
//
// Two independent role axes:
//   trust role       sender | receiver   — fixed by which device holds keys
//   rendezvous role  presenter | entrant — free choice (who shows the code)
// Decoupling them is what makes a camera optional: the pairing code carries
// only a short rendezvous id, never key material, so it can be typed by hand.
// iOS is most often the SENDER to a desktop receiver, so the
// presenter-with-typed-code path is mandatory — never gate pairing on a camera.
enum DevicePairingCrypto {

    enum Error: Swift.Error {
        case invalidPayload
        case invalidJWK
    }

    // Crockford base32: no I, L, O or U, so a typed code can't be misread.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let codeLength = 8

    // MARK: — Pairing code

    // ~40 bits. The code is a rendezvous identifier, NOT a secret — it only has
    // to avoid collisions and typos. Security comes from the private channel,
    // the SAS comparison, and the human confirmation on the sender.
    static func generateCode() -> String {
        var bytes = [UInt8](repeating: 0, count: codeLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, codeLength, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    // Lenient parse of a hand-typed code: case-insensitive, dashes/spaces
    // ignored, Crockford confusables folded (O→0, I/L→1). Returns nil when the
    // result isn't well-formed so callers can show a real error instead of
    // opening a channel nobody is listening on.
    static func normalizeCode(_ raw: String) -> String? {
        let cleaned = raw
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        guard cleaned.count == codeLength, cleaned.allSatisfy({ alphabet.contains($0) }) else {
            return nil
        }
        return cleaned
    }

    // Display form: XXXX-XXXX, easier to read aloud and to copy accurately.
    static func formatCode(_ code: String) -> String {
        guard code.count == codeLength else { return code }
        let mid = code.index(code.startIndex, offsetBy: 4)
        return "\(code[code.startIndex..<mid])-\(code[mid...])"
    }

    // MARK: — Handshake

    // Per-session ephemeral keypair. Memory-only by contract — never write these
    // to the Keychain or the database; the point is that the transfer key is
    // unrecoverable once the session ends.
    static func generateEphemeralKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    // Raw 32-byte ECDH shared secret, used directly as the AES-256-GCM transfer
    // key AND as the SAS input — the same no-HKDF convention the message
    // envelope KEK already uses. Do NOT use hkdfDerivedSymmetricKey here.
    static func deriveTransferSecret(
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        theirPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
        return shared.withUnsafeBytes { Data($0) }
    }

    // Short authentication string — the load-bearing anti-MITM control. Both
    // sides derive it independently; a relay in the middle necessarily holds two
    // *different* shared secrets and so produces two different codes, which the
    // human comparing the screens will catch.
    //
    // Pinned formula (must match web byte-for-byte):
    //   first 4 bytes of SHA-256(secret ‖ "yaply-sas-v1"), big-endian,
    //   mod 1_000_000, zero-padded to 6 digits.
    static func deriveSasCode(secret: Data) -> String {
        var input = secret
        input.append(Data("yaply-sas-v1".utf8))
        let digest = Array(SHA256.hash(data: input))
        let n = (UInt32(digest[0]) << 24)
            | (UInt32(digest[1]) << 16)
            | (UInt32(digest[2]) << 8)
            | UInt32(digest[3])
        return String(format: "%06d", n % 1_000_000)
    }

    // MARK: — Transfer payload

    // One entry per identity keypair the sender knows: its own, plus everything
    // it received from earlier pairings. Passing the whole set along is what lets
    // linking chains propagate history access transitively (A links B, B links C,
    // and C can still read everything A could).
    struct EscrowedKey: Codable {
        let deviceId: Int
        let pub: JWK
        let priv: JWK

        enum CodingKeys: String, CodingKey {
            case deviceId = "deviceId"
            case pub, priv
        }
    }

    // Tolerant JWK: web's Web Crypto output also carries `ext: Bool` and
    // `key_ops: [String]`, which a blanket [String: String] decode chokes on.
    // Decoding only the fields we need — and omitting the optional ones when
    // encoding — keeps both directions interoperable.
    struct JWK: Codable {
        var kty: String? = "EC"
        var crv: String? = "P-256"
        let x: String
        let y: String
        var d: String?   // present only on private keys
    }

    static func jwk(from privateKey: P256.KeyAgreement.PrivateKey) -> JWK {
        let x963 = privateKey.publicKey.x963Representation
        return JWK(
            x: x963[1..<33].base64URLEncodedString(),
            y: x963[33..<65].base64URLEncodedString(),
            d: privateKey.rawRepresentation.base64URLEncodedString()
        )
    }

    static func publicJWK(from publicKey: P256.KeyAgreement.PublicKey) -> JWK {
        let x963 = publicKey.x963Representation
        return JWK(
            x: x963[1..<33].base64URLEncodedString(),
            y: x963[33..<65].base64URLEncodedString(),
            d: nil
        )
    }

    static func privateKey(from jwk: JWK) throws -> P256.KeyAgreement.PrivateKey {
        guard let dStr = jwk.d, let dData = Data(base64URLEncoded: dStr), dData.count == 32 else {
            throw Error.invalidJWK
        }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: dData)
    }

    static func publicKey(from jwk: JWK) throws -> P256.KeyAgreement.PublicKey {
        guard
            let xData = Data(base64URLEncoded: jwk.x),
            let yData = Data(base64URLEncoded: jwk.y),
            xData.count == 32, yData.count == 32
        else { throw Error.invalidJWK }
        var x963 = Data([0x04])
        x963.append(xData)
        x963.append(yData)
        return try P256.KeyAgreement.PublicKey(x963Representation: x963)
    }

    struct TransferPayload: Codable {
        let iv: String          // base64(nonce[12])
        let ciphertext: String  // base64(AES-GCM(transferKey, JSON keys) + tag)
    }

    static func encryptTransferPayload(secret: Data, keys: [EscrowedKey]) throws -> TransferPayload {
        let key = SymmetricKey(data: secret)
        let plaintext = try JSONEncoder().encode(keys)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }
        return TransferPayload(
            iv: iv.base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
    }

    static func decryptTransferPayload(secret: Data, payload: TransferPayload) throws -> [EscrowedKey] {
        guard
            let ivData = Data(base64Encoded: payload.iv),
            let combined = Data(base64Encoded: payload.ciphertext),
            combined.count > 16
        else { throw Error.invalidPayload }
        let key = SymmetricKey(data: secret)
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: ivData),
            ciphertext: combined.dropLast(16),
            tag: combined.suffix(16)
        )
        let plaintext = try AES.GCM.open(sealed, using: key)
        return try JSONDecoder().decode([EscrowedKey].self, from: plaintext)
    }
}
