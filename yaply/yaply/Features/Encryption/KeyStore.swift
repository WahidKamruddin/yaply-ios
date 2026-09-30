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

    private static let identityPrivatePrefix = "yaply.identity.private."
    private static let identityPublicPrefix  = "yaply.identity.public."
    // Pre-scoping single slot — read only by the one-time migration and clearAllKeys.
    private static let legacyIdentityPrivate = "yaply.identity.private"
    private static let legacyIdentityPublic  = "yaply.identity.public"
    private static let deviceIdPrefix   = "yaply.deviceId."
    private static let escrowPrefix     = "yaply.escrow."

    // MARK: — Identity keypair

    /// Resolved decrypt keys, keyed by **user id first**, then fingerprint.
    ///
    /// `privateKey(forFingerprint:userId:)` hits the Keychain twice per call
    /// (identity pair + escrow list), and decrypting a page calls it once per
    /// message — so a 50-message page meant ~100 Keychain reads.
    ///
    /// The user-id keying is load-bearing, not tidiness: the web client shipped
    /// a bug where a single mutable slot plus an "is this the same owner?"
    /// check let a straggling async call from a signed-out account repopulate
    /// the slot, so every decrypt for the newly signed-in account failed. A
    /// per-user dictionary cannot express that state. Never replace this with a
    /// single slot. Any write to the underlying key material clears it.
    private static var privateKeyCache: [UUID: [String: P256.KeyAgreement.PrivateKey]] = [:]

    private static func invalidatePrivateKeyCache(forUser userId: UUID? = nil) {
        if let userId {
            privateKeyCache.removeValue(forKey: userId)
        } else {
            privateKeyCache.removeAll()
        }
    }

    // Scoped per user, like the device id and escrow slots. A single fixed slot
    // let the next account on a handed-off device (Keychain items survive an app
    // delete) inherit the previous account's keypair and republish it as its own.
    private static func identityPrivateKey(forUser userId: UUID) -> String { identityPrivatePrefix + userId.uuidString }
    private static func identityPublicKey(forUser userId: UUID) -> String { identityPublicPrefix + userId.uuidString }

    static func storeIdentityKeyPair(_ privateKey: P256.KeyAgreement.PrivateKey, forUser userId: UUID) throws {
        invalidatePrivateKeyCache(forUser: userId)
        try KeychainService.save(
            key: identityPrivateKey(forUser: userId),
            data: privateKey.rawRepresentation,  // 32-byte private scalar
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        try KeychainService.save(
            key: identityPublicKey(forUser: userId),
            data: privateKey.publicKey.x963Representation,  // 65-byte uncompressed point
            accessible: kSecAttrAccessibleAfterFirstUnlock
        )
    }

    static func loadIdentityKeyPair(forUser userId: UUID) throws -> P256.KeyAgreement.PrivateKey? {
        try adoptLegacyIdentityIfOwned(by: userId)
        guard let privData = try KeychainService.load(key: identityPrivateKey(forUser: userId)) else { return nil }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: privData)
    }

    static func loadIdentityPublicKey(forUser userId: UUID) throws -> P256.KeyAgreement.PublicKey? {
        try adoptLegacyIdentityIfOwned(by: userId)
        guard let pubData = try KeychainService.load(key: identityPublicKey(forUser: userId)) else { return nil }
        return try P256.KeyAgreement.PublicKey(x963Representation: pubData)
    }

    /// One-time migration of the pre-scoping single-slot identity pair.
    ///
    /// Ownership is decided by the user-scoped device id, which has always been
    /// written alongside the keypair: only a user who has a stored device id on
    /// this install registered that key. Anyone else (a different account that
    /// signed in on a handed-off device) gets nothing and generates a fresh pair.
    /// The legacy slot is removed once adopted, so it can never be adopted twice.
    private static func adoptLegacyIdentityIfOwned(by userId: UUID) throws {
        guard
            let legacyPriv = try KeychainService.load(key: legacyIdentityPrivate),
            try loadDeviceId(forUser: userId) != nil,
            try KeychainService.load(key: identityPrivateKey(forUser: userId)) == nil
        else { return }
        try KeychainService.save(
            key: identityPrivateKey(forUser: userId),
            data: legacyPriv,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        if let legacyPub = try KeychainService.load(key: legacyIdentityPublic) {
            try KeychainService.save(
                key: identityPublicKey(forUser: userId),
                data: legacyPub,
                accessible: kSecAttrAccessibleAfterFirstUnlock
            )
        }
        KeychainService.delete(key: legacyIdentityPrivate)
        KeychainService.delete(key: legacyIdentityPublic)
        invalidatePrivateKeyCache(forUser: userId)
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

    // MARK: — Escrowed keys (adopted from another device via live pairing)

    // Identity keypairs received over a pairing session. These are DECRYPT-ONLY:
    // this install never publishes them to `devices` and never seals new
    // messages to them — it keeps its own key for that. They exist solely so
    // history sealed to a device that already existed stays readable here.
    static func storeEscrowedKeys(_ keys: [DevicePairingCrypto.EscrowedKey], forUser userId: UUID) throws {
        invalidatePrivateKeyCache(forUser: userId)
        let data = try JSONEncoder().encode(keys)
        try KeychainService.save(
            key: escrowPrefix + userId.uuidString,
            data: data,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func loadEscrowedKeys(forUser userId: UUID) -> [DevicePairingCrypto.EscrowedKey] {
        guard
            let data = try? KeychainService.load(key: escrowPrefix + userId.uuidString),
            let keys = try? JSONDecoder().decode([DevicePairingCrypto.EscrowedKey].self, from: data)
        else { return [] }
        return keys
    }

    // Merges newly received keys into the local escrow, de-duplicated by public
    // key fingerprint. Merge rather than overwrite: pairing twice from two
    // different devices should union what each could read, not have the second
    // transfer silently drop the first one's keys.
    @discardableResult
    static func mergeEscrowedKeys(
        _ incoming: [DevicePairingCrypto.EscrowedKey],
        forUser userId: UUID
    ) throws -> [DevicePairingCrypto.EscrowedKey] {
        var byFingerprint: [String: DevicePairingCrypto.EscrowedKey] = [:]
        for key in loadEscrowedKeys(forUser: userId) + incoming {
            // Incoming keys come off the wire from another device, so validate
            // rather than trusting the shape.
            guard !key.pub.x.isEmpty, !key.pub.y.isEmpty, key.priv.d != nil else { continue }
            byFingerprint["\(key.pub.x).\(key.pub.y)"] = key
        }
        let merged = Array(byFingerprint.values)
        try storeEscrowedKeys(merged, forUser: userId)
        return merged
    }

    // Every fingerprint this install can decrypt with: its own device key first,
    // then any escrowed keys. Envelope lookups must use the whole list — a
    // message sealed before this device existed has no envelope for the own
    // fingerprint, but does have one for an escrowed device's, which is exactly
    // what makes history readable after pairing.
    static func candidateFingerprints(forUser userId: UUID) -> [String] {
        var fingerprints: [String] = []
        if let pub = try? loadIdentityPublicKey(forUser: userId) {
            fingerprints.append(EncryptionService.fingerprint(for: pub))
        }
        for key in loadEscrowedKeys(forUser: userId) {
            let fp = "\(key.pub.x).\(key.pub.y)"
            if !fingerprints.contains(fp) { fingerprints.append(fp) }
        }
        return fingerprints
    }

    // Resolves the private key that can open an envelope sealed to `fingerprint`
    // — this install's own key, or one adopted via pairing.
    static func privateKey(forFingerprint fingerprint: String, userId: UUID) -> P256.KeyAgreement.PrivateKey? {
        if let cached = privateKeyCache[userId]?[fingerprint] { return cached }
        guard let resolved = resolvePrivateKey(forFingerprint: fingerprint, userId: userId) else {
            // Deliberately not cached: a miss can become a hit once pairing
            // adopts an escrowed key, and caching nil would make that permanent.
            return nil
        }
        privateKeyCache[userId, default: [:]][fingerprint] = resolved
        return resolved
    }

    private static func resolvePrivateKey(forFingerprint fingerprint: String, userId: UUID) -> P256.KeyAgreement.PrivateKey? {
        if let own = try? loadIdentityKeyPair(forUser: userId),
           EncryptionService.fingerprint(for: own.publicKey) == fingerprint {
            return own
        }
        for key in loadEscrowedKeys(forUser: userId) where "\(key.pub.x).\(key.pub.y)" == fingerprint {
            return try? DevicePairingCrypto.privateKey(from: key.priv)
        }
        return nil
    }

    // The full set this install can hand to a new device: its own identity pair
    // plus everything already escrowed here.
    static func transferableKeys(forUser userId: UUID) -> [DevicePairingCrypto.EscrowedKey] {
        var out = loadEscrowedKeys(forUser: userId)
        guard let own = try? loadIdentityKeyPair(forUser: userId) else { return out }
        let ownJWK = DevicePairingCrypto.jwk(from: own)
        let ownFp = "\(ownJWK.x).\(ownJWK.y)"
        if !out.contains(where: { "\($0.pub.x).\($0.pub.y)" == ownFp }) {
            out.append(DevicePairingCrypto.EscrowedKey(
                deviceId: ((try? loadDeviceId(forUser: userId)) ?? nil) ?? 0,
                pub: DevicePairingCrypto.publicJWK(from: own.publicKey),
                priv: ownJWK
            ))
        }
        return out
    }

    // MARK: — Clear (called on sign-out and on revocation, mirrors clearAllKeys)

    static func clearAllKeys() {
        invalidatePrivateKeyCache()
        // Both prefixes also match the legacy unscoped names.
        KeychainService.deleteAll(prefix: legacyIdentityPrivate)
        KeychainService.deleteAll(prefix: legacyIdentityPublic)
        KeychainService.deleteAll(prefix: deviceIdPrefix)
        KeychainService.deleteAll(prefix: escrowPrefix)
    }
}
