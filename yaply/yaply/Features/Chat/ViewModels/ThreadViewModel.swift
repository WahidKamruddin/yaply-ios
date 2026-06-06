import Supabase
import CryptoKit
import Foundation
import Realtime

@Observable
@MainActor
final class ThreadViewModel {
    private(set) var replies: [DecryptedMessage] = []
    private(set) var isLoading = false
    private(set) var isSending = false
    var error: String?

    let rootMessage: DecryptedMessage
    private let conversationId: UUID
    private let currentUserId: UUID
    private let repository = MessageRepository()
    private var realtimeTask: Task<Void, Never>?

    init(rootMessage: DecryptedMessage, conversationId: UUID, currentUserId: UUID) {
        self.rootMessage = rootMessage
        self.conversationId = conversationId
        self.currentUserId = currentUserId
    }

    func onAppear() async {
        isLoading = true
        await load()
        isLoading = false
        startRealtime()
    }

    func onDisappear() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    func load() async {
        do {
            let raw = try await repository.fetchThreadMessages(threadRootId: rootMessage.id)
            let otherUser = raw.first(where: { $0.senderId != nil && $0.senderId != currentUserId })?.senderId
            replies = await decryptAll(raw, otherUserId: otherUser)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sendReply(text: String) async {
        guard !text.isBlank else { return }
        isSending = true
        defer { isSending = false }

        let otherUserId = replies.first(where: { $0.senderId != nil && $0.senderId != currentUserId })?.senderId
            ?? (rootMessage.senderId != currentUserId ? rootMessage.senderId : nil)

        let (content, iv) = await encrypt(plaintext: text, otherUserId: otherUserId)
        let params = SendMessageParams(
            conversationId: conversationId,
            senderId: currentUserId,
            content: content,
            iv: iv,
            type: "text",
            replyToId: rootMessage.id,
            threadId: rootMessage.id
        )
        do {
            let sent = try await repository.sendMessage(params)
            replies.append(DecryptedMessage(
                id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                content: text, type: sent.type, replyToId: rootMessage.id,
                threadId: rootMessage.id, createdAt: sent.createdAt
            ))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Realtime

    private func startRealtime() {
        realtimeTask = Task {
            let channel = supabase.channel("thread-\(rootMessage.id.uuidString)-\(UUID().uuidString)")
            let inserts = channel.postgresChange(
                InsertAction.self, schema: "public", table: "messages",
                filter: .eq("thread_id", value: rootMessage.id.uuidString)
            )
            try? await channel.subscribeWithError()
            for await _ in inserts { await load() }
            await supabase.removeChannel(channel)
        }
    }

    // MARK: - Encryption (mirrors ChatViewModel)

    private func decryptAll(_ raw: [DbMessage], otherUserId: UUID?) async -> [DecryptedMessage] {
        var result: [DecryptedMessage] = []
        for msg in raw {
            var content = msg.content
            let isFromOther = msg.senderId != nil && msg.senderId != currentUserId
            if isFromOther, let otherId = msg.senderId ?? otherUserId {
                content = await decryptContent(msg.content, iv: msg.iv, otherUserId: otherId)
            } else if msg.iv == nil {
                content = EncryptionService.decryptLegacy(msg.content) ?? msg.content
            }
            result.append(DecryptedMessage(
                id: msg.id, conversationId: msg.conversationId, senderId: msg.senderId,
                content: content, type: msg.type, mediaUrl: msg.mediaUrl,
                replyToId: msg.replyToId, threadId: msg.threadId,
                editedAt: msg.editedAt, deletedAt: msg.deletedAt, createdAt: msg.createdAt,
                senderProfile: msg.senderProfile
            ))
        }
        return result
    }

    private func encrypt(plaintext: String, otherUserId: UUID?) async -> (content: String, iv: String?) {
        guard let otherUserId else {
            return (Data(plaintext.utf8).base64EncodedString(), nil)
        }
        do {
            let key = try await sharedKey(for: otherUserId)
            let result = try EncryptionService.encryptMessage(plaintext, key: key)
            return result
        } catch {
            return (Data(plaintext.utf8).base64EncodedString(), nil)
        }
    }

    private func decryptContent(_ content: String, iv: String?, otherUserId: UUID) async -> String {
        do {
            let key = try await sharedKey(for: otherUserId)
            return try EncryptionService.decryptMessage(content: content, iv: iv, key: key)
        } catch {
            return EncryptionService.decryptLegacy(content) ?? content
        }
    }

    private func sharedKey(for otherUserId: UUID) async throws -> SymmetricKey {
        if let cached = try? KeyStore.loadDerivedKey(forConversation: conversationId) { return cached }

        guard let myPrivKey = try KeyStore.loadIdentityKeyPair() else {
            throw EncryptionService.Error.invalidJWK
        }

        struct DeviceKeyRow: Decodable {
            struct JWKCoords: Decodable { let x: String; let y: String }
            let identityKey: JWKCoords?
            enum CodingKeys: String, CodingKey { case identityKey = "identity_key" }
        }

        let row: DeviceKeyRow = try await supabase
            .from("devices")
            .select("identity_key")
            .eq("user_id", value: otherUserId.uuidString)
            .eq("device_id", value: 1)
            .single()
            .execute()
            .value

        guard let coords = row.identityKey else { throw EncryptionService.Error.invalidJWK }
        let pubKey = try EncryptionService.publicKeyFromJWK(["x": coords.x, "y": coords.y])
        let key = try EncryptionService.deriveSharedKey(myPrivateKey: myPrivKey, theirPublicKey: pubKey)
        try KeyStore.storeDerivedKey(key, forConversation: conversationId)
        return key
    }
}
