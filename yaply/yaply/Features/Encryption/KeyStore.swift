import CryptoKit
import Foundation
import CryptoKit

// Keychain-backed key storage. Mirrors packages/crypto/src/keyStore.ts.
//
// IndexedDB → Keychain mapping:
//   STORE_IDENTITY "pub"       → "yaply.identity.public"    (x963 bytes, 65 bytes)
//   STORE_IDENTITY "priv"      → "yaply.identity.private"   (raw scalar, 32 bytes)
//   STORE_IDENTITY deviceId:<u> → "yaply.deviceId.<UUID>"   (this install's device_id)
//
// v2: there is no per-conversation derived key anymore — every message is sealed
// with a fresh per-message key wrapped per recipient device (see EncryptionService
// wrapKey/unwrapKey), so the old STORE_DERIVED slot is retired.
//
// Access control: private keys use afterFirstUnlockThisDeviceOnly — unavailable
// before first unlock and excluded from iCloud backup.
enum KeyStore {

    private static let identityPrivate  = "yaply.identity.private"
    private static let identityPublic   = "yaply.identity.public"
    private static let deviceIdPrefix   = "yaply.deviceId."

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

    // MARK: — Per-install device id (v2 — random per install, never hardcoded to 1)

    static func storeDeviceId(_ id: Int, forUser userId: UUID) throws {
        try KeychainService.save(
            key: deviceIdPrefix + userId.uuidString,
            data: Data(String(id).utf8),
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func loadDeviceId(forUser userId: UUID) throws -> Int? {
        guard
            let data = try KeychainService.load(key: deviceIdPrefix + userId.uuidString),
            let str = String(data: data, encoding: .utf8),
            let id = Int(str)
        else { return nil }
        return id
    }

    // MARK: — Clear (called on sign-out, mirrors clearAllKeys)

    static func clearAllKeys() {
        KeychainService.delete(key: identityPrivate)
        KeychainService.delete(key: identityPublic)
        KeychainService.deleteAll(prefix: deviceIdPrefix)
    }
}
