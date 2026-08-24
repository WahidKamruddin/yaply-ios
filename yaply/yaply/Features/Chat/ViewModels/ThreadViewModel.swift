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
    // Loaded lazily from the parent conversation on first send/decrypt.
    private var memberUserIds: [UUID]?

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
            replies = await decryptAll(raw)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sendReply(text: String) async {
        guard !text.isBlank else { return }
        isSending = true
        defer { isSending = false }

        do {
            try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: currentUserId)
            let memberIds = await resolvedMemberIds()

            let sent: DbMessage
            if let sealed = await EnvelopeEncryption.encryptForMembers(
                plaintext: text, memberUserIds: memberIds, repository: repository
            ) {
                let params = SendMessageWithEnvelopesParams(
                    pConversationId: conversationId, pContent: sealed.content, pIv: sealed.iv,
                    pEnvelopes: sealed.envelopes, pType: "text",
                    pReplyToId: rootMessage.id, pThreadId: rootMessage.id,
                    pMediaUrl: nil, pMediaMime: nil
                )
                sent = try await repository.sendMessageWithEnvelopes(params)
            } else {
                let params = SendMessageParams(
                    conversationId: conversationId, senderId: currentUserId,
                    content: Data(text.utf8).base64EncodedString(), iv: nil, type: "text",
                    replyToId: rootMessage.id, threadId: rootMessage.id
                )
                sent = try await repository.sendMessage(params)
            }
            replies.append(DecryptedMessage(
                id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                content: text, type: sent.type, replyToId: rootMessage.id,
                threadId: rootMessage.id, createdAt: sent.createdAt
            ))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Every member of the parent conversation, including the sender — fetched once
    // and cached for the life of this thread's view model.
    private func resolvedMemberIds() async -> [UUID] {
        if let cached = memberUserIds { return cached }
        struct MemberRow: Decodable {
            let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        let rows: [MemberRow] = (try? await supabase
            .from("conversation_members")
            .select("user_id")
            .eq("conversation_id", value: conversationId.uuidString)
            .execute()
            .value) ?? []
        var ids = Set(rows.map(\.userId))
        ids.insert(currentUserId)
        let resolved = Array(ids)
        memberUserIds = resolved
        return resolved
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

    // MARK: - Encryption (v2 — mirrors ChatViewModel's decryptDbMessage)

    private func decryptAll(_ raw: [DbMessage]) async -> [DecryptedMessage] {
        var result: [DecryptedMessage] = []
        for msg in raw {
            let (content, failed) = await decryptDbMessage(msg)
            result.append(DecryptedMessage(
                id: msg.id, conversationId: msg.conversationId, senderId: msg.senderId,
                content: content, type: msg.type, mediaUrl: msg.mediaUrl,
                replyToId: msg.replyToId, threadId: msg.threadId,
                editedAt: msg.editedAt, deletedAt: msg.deletedAt, createdAt: msg.createdAt,
                senderProfile: msg.senderProfile, decryptFailed: failed
            ))
        }
        return result
    }

    private func decryptDbMessage(_ msg: DbMessage) async -> (content: String, failed: Bool) {
        if msg.encV == 2 {
            guard let iv = msg.iv else { return ("", true) }
            // Await registration BEFORE giving up on a missing identity key — a
            // device that hasn't finished registering yet must get the chance to
            // before this is reported as a decrypt failure.
            try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: currentUserId)
            // No own-key guard here: an escrowed key adopted via pairing can
            // open envelopes this device's own key never could, so the candidate
            // lookup inside decryptV2 decides — not the presence of a local pair.
            guard let plaintext = await EnvelopeEncryption.decryptV2(
                messageId: msg.id, content: msg.content, iv: iv,
                repository: repository, userId: currentUserId
            ) else { return ("", true) }
            return (plaintext, false)
        } else if msg.encV == nil && msg.iv == nil {
            return (EncryptionService.decryptLegacy(msg.content) ?? msg.content, false)
        } else {
            return ("", true)
        }
    }

}
