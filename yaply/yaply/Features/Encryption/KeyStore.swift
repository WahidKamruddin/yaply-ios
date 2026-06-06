import CryptoKit
import Foundation
import CryptoKit

// Keychain-backed key storage. Mirrors packages/crypto/src/keyStore.ts.
//
// IndexedDB → Keychain mapping:
//   STORE_IDENTITY "pub"  → "yaply.identity.public"   (x963 bytes, 65 bytes)
//   STORE_IDENTITY "priv" → "yaply.identity.private"  (raw scalar, 32 bytes)
//   STORE_DERIVED  convId → "yaply.derived.<UUID>"    (raw AES key, 32 bytes)
//
// Access control: private keys use afterFirstUnlockThisDeviceOnly — unavailable
// before first unlock and excluded from iCloud backup.
enum KeyStore {

    private static let identityPrivate  = "yaply.identity.private"
    private static let identityPublic   = "yaply.identity.public"
    private static let derivedPrefix    = "yaply.derived."

    // MARK: — Identity keypair

    static func storeIdentityKeyPair(_ privateKey: P256.KeyAgreement.PrivateKey) throws {
        try KeychainService.save(
            key: identityPrivate,
            data: privateKey.rawRepresentation,  // 32-byte private scalar
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        try KeychainService.save(
            key: identityPublic,
            data: privateKey.publicKey.x963Representation,  // 65-byte uncompressed point
            accessible: kSecAttrAccessibleAfterFirstUnlock
        )
    }

    static func loadIdentityKeyPair() throws -> P256.KeyAgreement.PrivateKey? {
        guard let privData = try KeychainService.load(key: identityPrivate) else { return nil }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: privData)
    }

    static func loadIdentityPublicKey() throws -> P256.KeyAgreement.PublicKey? {
        guard let pubData = try KeychainService.load(key: identityPublic) else { return nil }
        return try P256.KeyAgreement.PublicKey(x963Representation: pubData)
    }

    // MARK: — Derived (shared) keys per conversation

    static func storeDerivedKey(_ key: SymmetricKey, forConversation id: UUID) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try KeychainService.save(
            key: derivedPrefix + id.uuidString,
            data: data,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func loadDerivedKey(forConversation id: UUID) throws -> SymmetricKey? {
        guard let data = try KeychainService.load(key: derivedPrefix + id.uuidString) else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    // MARK: — Clear (called on sign-out, mirrors clearAllKeys)

    static func clearAllKeys() {
        KeychainService.delete(key: identityPrivate)
        KeychainService.delete(key: identityPublic)
        KeychainService.deleteAll(prefix: derivedPrefix)
    }
}
