import Supabase
import CryptoKit
import Foundation

@Observable
final class ChatViewModel {
    private(set) var messages: [DecryptedMessage] = []
    private(set) var isLoading = false
    private(set) var isSending = false
    var error: String?
    var replyToMessage: DecryptedMessage?

    // Pagination
    private var nextCursor: Date?
    private(set) var hasMore = false

    private let conversationId: UUID
    private let currentUserId: UUID
    private let repository = MessageRepository()
    private var realtimeTask: Task<Void, Never>?

    init(conversationId: UUID, currentUserId: UUID) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
    }

    // MARK: — Lifecycle

    func onAppear() async {
        isLoading = true
        await loadMessages()
        isLoading = false
        startRealtime()
    }

    func onDisappear() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    // MARK: — Message loading + decryption

    func loadMessages() async {
        do {
            let (raw, cursor) = try await repository.fetchMessages(conversationId: conversationId)
            nextCursor = cursor
            hasMore = cursor != nil
            messages = await decryptAll(raw, otherUserId: otherUserId(from: raw))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadOlderMessages() async {
        guard hasMore, let cursor = nextCursor else { return }
        do {
            let (raw, newCursor) = try await repository.fetchMessages(conversationId: conversationId, cursor: cursor)
            nextCursor = newCursor
            hasMore = newCursor != nil
            let older = await decryptAll(raw, otherUserId: otherUserId(from: raw))
            messages = older + messages
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: — Send

    func sendMessage(text: String) async {
        guard !text.isBlank else { return }
        isSending = true
        defer { isSending = false }

        let otherUser = otherUserId(from: messages)
        let encrypted = await encrypt(plaintext: text, otherUserId: otherUser)
        let params = SendMessageParams(
            conversationId: conversationId,
            senderId: currentUserId,
            encryptedContent: encrypted,
            parentMessageId: replyToMessage?.id
        )

        do {
            let sent = try await repository.sendMessage(params)
            let decrypted = DecryptedMessage(
                id: sent.id,
                conversationId: sent.conversationId,
                senderId: sent.senderId,
                content: text,
                messageType: sent.messageType,
                contentHint: sent.contentHint,
                attachmentRef: sent.encryptedAttachmentRef,
                parentMessageId: sent.parentMessageId,
                threadName: sent.threadName,
                deletedAt: sent.deletedAt,
                serverTimestamp: sent.serverTimestamp
            )
            messages.append(decrypted)
            replyToMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteMessage(id: UUID) async {
        do {
            try await repository.softDelete(messageId: id)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx] = DecryptedMessage(
                    id: messages[idx].id,
                    conversationId: messages[idx].conversationId,
                    senderId: messages[idx].senderId,
                    content: messages[idx].content,
                    messageType: messages[idx].messageType,
                    deletedAt: Date(),
                    serverTimestamp: messages[idx].serverTimestamp
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: — Real-time (mirrors useRealtimeMessages — re-fetch on insert, don't parse payload)

    private func startRealtime() {
        realtimeTask = Task {
            let channel = supabase.channel("messages-\(conversationId.uuidString)")
            let inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "messages",
                filter: .init(column: "conversation_id", operator: .eq, value: conversationId.uuidString)
            )
            await channel.subscribe()
            for await _ in inserts {
                await loadLatestMessages()
            }
        }
    }

    // Fetches the most recent page to pick up any messages we don't have yet
    private func loadLatestMessages() async {
        guard let (raw, _) = try? await repository.fetchMessages(conversationId: conversationId) else { return }
        let incoming = await decryptAll(raw, otherUserId: otherUserId(from: raw))
        let existingIds = Set(messages.map(\.id))
        let newOnes = incoming.filter { !existingIds.contains($0.id) }
        if !newOnes.isEmpty {
            messages.append(contentsOf: newOnes.sorted { $0.serverTimestamp < $1.serverTimestamp })
        }
    }

    // MARK: — Encryption helpers (mirrors useEncryption hook)

    private func encrypt(plaintext: String, otherUserId: UUID?) async -> String {
        guard let otherUserId else {
            return Data(plaintext.utf8).base64EncodedString()
        }
        do {
            let key = try await sharedKey(for: otherUserId)
            return try EncryptionService.encryptMessage(plaintext, key: key)
        } catch {
            return Data(plaintext.utf8).base64EncodedString()
        }
    }

    private func decryptAll(_ raw: [DbMessage], otherUserId: UUID?) async -> [DecryptedMessage] {
        var result: [DecryptedMessage] = []
        for msg in raw.reversed() {
            var content = msg.encryptedContent
            let isFromOther = msg.senderId != nil && msg.senderId != currentUserId

            if isFromOther, let otherId = msg.senderId ?? otherUserId {
                content = await decryptContent(msg.encryptedContent, otherUserId: otherId)
            } else {
                // Own messages — base64 fallback (we didn't cache the key used at send time)
                content = EncryptionService.decryptLegacy(msg.encryptedContent) ?? msg.encryptedContent
            }

            result.append(DecryptedMessage(
                id: msg.id,
                conversationId: msg.conversationId,
                senderId: msg.senderId,
                content: content,
                messageType: msg.messageType,
                contentHint: msg.contentHint,
                attachmentRef: msg.encryptedAttachmentRef,
                parentMessageId: msg.parentMessageId,
                threadName: msg.threadName,
                deletedAt: msg.deletedAt,
                serverTimestamp: msg.serverTimestamp,
                senderProfile: msg.senderProfile
            ))
        }
        return result
    }

    private func decryptContent(_ ciphertext: String, otherUserId: UUID) async -> String {
        do {
            let key = try await sharedKey(for: otherUserId)
            return try EncryptionService.decryptMessage(ciphertext, key: key)
        } catch {
            return EncryptionService.decryptLegacy(ciphertext) ?? ciphertext
        }
    }

    // Derive + cache shared key (mirrors useEncryption's encrypt/decrypt key-loading logic)
    private func sharedKey(for otherUserId: UUID) async throws -> SymmetricKey {
        if let cached = try? KeyStore.loadDerivedKey(forConversation: conversationId) {
            return cached
        }

        guard let myPrivKey = try KeyStore.loadIdentityKeyPair() else {
            throw EncryptionService.Error.invalidJWK
        }

        struct DeviceKeyRow: Decodable {
            let identityKey: [String: String]?
            enum CodingKeys: String, CodingKey { case identityKey = "identity_key" }
        }

        let deviceRow: DeviceKeyRow = try await supabase
            .from("devices")
            .select("identity_key")
            .eq("user_id", value: otherUserId.uuidString)
            .eq("device_id", value: "1")
            .single()
            .execute()
            .value

        guard let jwk = deviceRow.identityKey else { throw EncryptionService.Error.invalidJWK }
        let theirKey = try EncryptionService.publicKeyFromJWK(jwk)
        let sharedKey = try EncryptionService.deriveSharedKey(myPrivateKey: myPrivKey, theirPublicKey: theirKey)
        try? KeyStore.storeDerivedKey(sharedKey, forConversation: conversationId)
        return sharedKey
    }

    // Infer the other participant's user ID from the message list (for direct chats)
    private func otherUserId(from messages: [DecryptedMessage]) -> UUID? {
        messages.first(where: { $0.senderId != currentUserId })?.senderId
    }

    private func otherUserId(from raw: [DbMessage]) -> UUID? {
        raw.first(where: { $0.senderId != currentUserId })?.senderId
    }
}
