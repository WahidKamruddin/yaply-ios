import CryptoKit
import Foundation
import Supabase
import Realtime

// Mirrors src/features/pairing/hooks/useDevicePairing.ts.
//
// 'sender'   — this device already holds keys and will hand them over.
// 'receiver' — this device just signed in and needs history access.
// Independent of who displayed the code; either role can present or enter it.
enum PairingTrustRole: Hashable, Identifiable {
    case sender
    case receiver

    var id: Self { self }
}

enum PairingPhase: Equatable {
    case idle
    case waiting       // channel open, other device hasn't shown up yet
    case verifying     // both sides have a shared secret; compare the SAS
    case transferring  // sender released the keys, receiver is importing
    case done
    case expired
    case failed(String)
}

@MainActor
@Observable
final class DevicePairingViewModel {

    // How long a pairing code stays usable. Short on purpose: the code is
    // visible on screen, so the window in which a stale one could be reused
    // should be measured in seconds, not minutes.
    static let ttl: Duration = .seconds(90)

    private(set) var phase: PairingPhase = .idle
    private(set) var role: PairingTrustRole?
    private(set) var code: String?
    private(set) var sas: String?
    private(set) var importedCount = 0

    private let userId: UUID
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    // Ephemeral material is memory-only by contract — never persisted, and
    // dropped as soon as the session ends so the transfer key can't be
    // recovered afterwards.
    private var myEphemeral: P256.KeyAgreement.PrivateKey?
    private var peerEphPub: String?
    private var secret: Data?

    init(userId: UUID) {
        self.userId = userId
    }

    var formattedCode: String? { code.map(DevicePairingCrypto.formatCode) }

    // `pairingCode` nil → this device presents a freshly generated code.
    // Provided → this device is entering a code shown on the other one. Either
    // way both sides run the identical protocol; presenting is not consent.
    func start(role: PairingTrustRole, pairingCode: String? = nil) {
        cancel()
        let activeCode = pairingCode ?? DevicePairingCrypto.generateCode()
        self.role = role
        self.code = activeCode
        self.phase = .waiting

        let ephemeral = DevicePairingCrypto.generateEphemeralKeyPair()
        myEphemeral = ephemeral
        let myEphPubJSON = jsonString(DevicePairingCrypto.publicJWK(from: ephemeral.publicKey))

        listenTask = Task { [weak self] in
            guard let self else { return }
            let ch = supabase.channel("pairing:\(userId.uuidString.lowercased()):\(activeCode)") {
                $0.isPrivate = true
            }
            let ready = ch.broadcastStream(event: "ready")
            let hello = ch.broadcastStream(event: "hello")
            let ack = ch.broadcastStream(event: "ack")
            let payload = ch.broadcastStream(event: "payload")
            let done = ch.broadcastStream(event: "done")

            do {
                try await ch.subscribeWithError()
            } catch {
                self.phase = .failed("Could not open a secure channel. Check your connection and try again.")
                return
            }
            self.channel = ch

            // Announce presence so the other side re-sends — neither device can
            // rely on having joined first.
            if role == .sender {
                await ch.broadcast(event: "ready", message: [:])
            } else {
                await ch.broadcast(event: "hello", message: ["ephPub": .string(myEphPubJSON)])
            }

            await withTaskGroup(of: Void.self) { group in
                if role == .sender {
                    group.addTask { [weak self] in
                        for await message in hello {
                            guard let self, let ephPub = Self.inner(message)["ephPub"]?.stringValue else { continue }
                            if await self.adoptPeer(ephPub) {
                                // Re-ack even on a duplicate hello, in case the
                                // first ack was lost.
                                await ch.broadcast(event: "ack", message: ["ephPub": .string(myEphPubJSON)])
                            }
                        }
                    }
                    group.addTask { [weak self] in
                        for await _ in done {
                            await self?.finish()
                            break
                        }
                    }
                } else {
                    group.addTask {
                        for await _ in ready {
                            await ch.broadcast(event: "hello", message: ["ephPub": .string(myEphPubJSON)])
                        }
                    }
                    group.addTask { [weak self] in
                        for await message in ack {
                            guard let self, let ephPub = Self.inner(message)["ephPub"]?.stringValue else { continue }
                            _ = await self.adoptPeer(ephPub)
                        }
                    }
                    group.addTask { [weak self] in
                        for await message in payload {
                            guard let self else { break }
                            await self.receivePayload(Self.inner(message), channel: ch)
                            break
                        }
                    }
                }
            }
        }

        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.ttl)
            guard let self, !Task.isCancelled else { return }
            // Let an in-flight transfer finish; only stall out the earlier phases.
            if self.phase == .waiting || self.phase == .verifying {
                self.phase = .expired
                self.teardown()
            }
        }
    }

    // Sender-only, and only after the human has confirmed the SAS matches on
    // both screens. This is the point of no return: keys leave the device here.
    func confirmAndSend() {
        guard role == .sender, let secret, let ch = channel else {
            phase = .failed("No secure channel — start over.")
            return
        }
        phase = .transferring
        Task {
            let keys = KeyStore.transferableKeys(forUser: userId)
            guard !keys.isEmpty else {
                phase = .failed("This device has no keys to share yet.")
                return
            }
            guard
                let payload = try? DevicePairingCrypto.encryptTransferPayload(secret: secret, keys: keys),
                let json = try? JSONEncoder().encode(payload),
                let object = try? JSONDecoder().decode(JSONObject.self, from: json)
            else {
                phase = .failed("Could not send the keys. Start over.")
                return
            }
            await ch.broadcast(event: "payload", message: object)
        }
    }

    func cancel() {
        teardown()
        phase = .idle
        role = nil
        code = nil
        sas = nil
        importedCount = 0
    }

    // MARK: — Protocol steps

    // Returns true once a shared secret exists for this peer.
    private func adoptPeer(_ ephPub: String) async -> Bool {
        // A second, *different* ephemeral key on the same session means two
        // devices are claiming the same role — abort rather than picking a
        // winner. Silently choosing one is exactly how a race turns into key
        // exfiltration.
        if let existing = peerEphPub, existing != ephPub {
            phase = .failed("Another device joined this pairing session. Cancelled for safety — start over.")
            teardown()
            return false
        }
        peerEphPub = ephPub
        if secret != nil { return true }

        guard
            let mine = myEphemeral,
            let data = ephPub.data(using: .utf8),
            let jwk = try? JSONDecoder().decode(DevicePairingCrypto.JWK.self, from: data),
            let theirs = try? DevicePairingCrypto.publicKey(from: jwk),
            let derived = try? DevicePairingCrypto.deriveTransferSecret(myPrivateKey: mine, theirPublicKey: theirs)
        else {
            phase = .failed("Couldn't establish a secure channel with that device.")
            return false
        }
        secret = derived
        sas = DevicePairingCrypto.deriveSasCode(secret: derived)
        phase = .verifying
        return true
    }

    private func receivePayload(_ message: JSONObject, channel ch: RealtimeChannelV2) async {
        guard
            let iv = message["iv"]?.stringValue,
            let ciphertext = message["ciphertext"]?.stringValue
        else { return }
        guard let secret else {
            phase = .failed("Received keys before the secure channel was established.")
            return
        }
        phase = .transferring
        do {
            let keys = try DevicePairingCrypto.decryptTransferPayload(
                secret: secret,
                payload: .init(iv: iv, ciphertext: ciphertext)
            )
            let merged = try KeyStore.mergeEscrowedKeys(keys, forUser: userId)
            importedCount = merged.count
            await ch.broadcast(event: "done", message: [:])
            phase = .done
            teardown()
        } catch {
            phase = .failed("Could not read the transferred keys. Start over.")
        }
    }

    private func finish() async {
        phase = .done
        teardown()
    }

    private func teardown() {
        expiryTask?.cancel(); expiryTask = nil
        listenTask?.cancel(); listenTask = nil
        if let ch = channel { Task { await supabase.removeChannel(ch) } }
        channel = nil
        myEphemeral = nil
        peerEphPub = nil
        secret = nil
    }

    // supabase-swift delivers the outer broadcast envelope; the sent data is
    // nested under "payload" (same unwrapping ChatViewModel does for typing).
    nonisolated private static func inner(_ message: JSONObject) -> JSONObject {
        message["payload"]?.objectValue ?? message
    }

    private func jsonString(_ jwk: DevicePairingCrypto.JWK) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(jwk), let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
