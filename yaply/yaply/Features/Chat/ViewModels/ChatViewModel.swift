import Supabase
import CryptoKit
import Foundation
import Realtime

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [DecryptedMessage] = []
    private(set) var isLoading = false
    private(set) var isSending = false
    var error: String?
    var replyToMessage: DecryptedMessage?
    private(set) var typingUsernames: [String] = []
    private(set) var reactionsMap: [UUID: [ReactionGroup]] = [:]

    // Read receipts
    private(set) var readByOtherSet: Set<UUID> = []
    private var markedReadIds: Set<UUID> = []

    // Group info
    private(set) var conversationMembers: [MemberSummary] = []
    private(set) var isGroupConversation = false

    private var nextCursor: Date?
    private(set) var hasMore = false

    private let conversationId: UUID
    private let currentUserId: UUID
    var currentUsername: String = ""
    private let repository = MessageRepository()
    private let uploadService = MediaUploadService()
    private var realtimeTask: Task<Void, Never>?
    private var pgChannel: RealtimeChannelV2?
    private var typingChannel: RealtimeChannelV2?
    private var typingTimers: [String: Task<Void, Never>] = [:]
    private var isTyping = false
    private var typingDebounce: Task<Void, Never>?

    // In-memory key caches — avoids Keychain reads on every message decrypt
    private var derivedKeyCache: SymmetricKey?
    private var identityPrivKeyCache: P256.KeyAgreement.PrivateKey?

    init(conversationId: UUID, currentUserId: UUID) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
    }

    // MARK: - Lifecycle

    func onAppear() async {
        isLoading = true
        await loadMessages()
        await loadConversationInfo()
        isLoading = false
        await preDeriveSharedKey()
        await markAndFetchReceipts()
        startRealtime()
    }

    private func preDeriveSharedKey() async {
        guard derivedKeyCache == nil else { return }
        // Use other member from loaded messages, falling back to conversationMembers
        let otherUser = otherUserId(from: messages)
            ?? conversationMembers.first(where: { $0.userId != currentUserId })?.userId
        guard let otherUser else { return }
        _ = try? await sharedKey(for: otherUser)
    }

    func onDisappear() {
        sendTypingEvent(false)
        typingDebounce?.cancel()
        realtimeTask?.cancel()
        realtimeTask = nil
        typingTimers.values.forEach { $0.cancel() }
        typingTimers = [:]
        if let ch = pgChannel {
            Task { await supabase.removeChannel(ch) }
            pgChannel = nil
        }
        if let ch = typingChannel {
            Task { await supabase.removeChannel(ch) }
            typingChannel = nil
        }
    }

    // MARK: - Message loading + decryption

    func loadMessages() async {
        do {
            let (raw, cursor) = try await repository.fetchMessages(conversationId: conversationId)
            nextCursor = cursor
            hasMore = cursor != nil
            messages = await decryptAll(raw, otherUserId: otherUserId(from: raw))
            await loadReactions()
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
            await loadReactions()
            await markAndFetchReceipts()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadReactions() async {
        let ids = messages.map(\.id)
        guard let raw = try? await repository.fetchReactions(messageIds: ids) else { return }
        reactionsMap = buildReactionGroups(from: raw)
    }

    private func loadReactionsForCurrentMessages() async {
        await loadReactions()
    }

    // MARK: - Read receipts

    private func markAndFetchReceipts() async {
        let unread = messages
            .filter { $0.senderId != currentUserId && !markedReadIds.contains($0.id) }
            .map(\.id)
        if !unread.isEmpty {
            unread.forEach { markedReadIds.insert($0) }
            do {
                try await repository.insertReadReceipts(unread, userId: currentUserId)
            } catch {
                unread.forEach { markedReadIds.remove($0) }
            }
        }
        await fetchReadStatus()
    }

    private func fetchReadStatus() async {
        let ownIds = messages.filter { $0.senderId == currentUserId }.map(\.id)
        if let set = try? await repository.fetchReadSet(messageIds: ownIds, currentUserId: currentUserId) {
            readByOtherSet = set
        }
    }

    // MARK: - Group info

    func loadConversationInfo() async {
        struct MemberRow: Decodable {
            let userId: UUID
            let role: String
            let profiles: Profile?
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"; case role; case profiles
            }
        }
        struct ConvInfo: Decodable {
            let type: String
            let conversationMembers: [MemberRow]
            enum CodingKeys: String, CodingKey {
                case type; case conversationMembers = "conversation_members"
            }
        }
        guard let info: ConvInfo = try? await supabase
            .from("conversations")
            .select("type, conversation_members(user_id, role, profiles(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at))")
            .eq("id", value: conversationId.uuidString)
            .single()
            .execute()
            .value
        else { return }

        isGroupConversation = info.type == "group"
        conversationMembers = info.conversationMembers.compactMap { cm in
            guard let profile = cm.profiles else { return nil }
            return MemberSummary(
                userId: cm.userId,
                profile: profile,
                isAdmin: cm.role == "owner" || cm.role == "admin",
                isMuted: false,
                lastReadAt: nil
            )
        }
    }

    private func buildReactionGroups(from reactions: [Reaction]) -> [UUID: [ReactionGroup]] {
        var map: [UUID: [String: (count: Int, reactedByMe: Bool)]] = [:]
        for r in reactions {
            if map[r.messageId] == nil { map[r.messageId] = [:] }
            let ex = map[r.messageId]![r.emoji] ?? (count: 0, reactedByMe: false)
            map[r.messageId]![r.emoji] = (count: ex.count + 1, reactedByMe: ex.reactedByMe || r.userId == currentUserId)
        }
        return map.mapValues { emojiMap in
            emojiMap.map { emoji, v in ReactionGroup(emoji: emoji, count: v.count, reactedByMe: v.reactedByMe) }
                .sorted { $0.count > $1.count }
        }
    }

    // MARK: - Send text

    func sendMessage(text: String) async {
        guard !text.isBlank else { return }

        // Optimistic: show message immediately before network round-trip
        let tempId = UUID()
        let capturedReplyTo = replyToMessage
        messages.append(DecryptedMessage(
            id: tempId, conversationId: conversationId, senderId: currentUserId,
            content: text, type: "text",
            replyToId: capturedReplyTo?.id, threadId: capturedReplyTo?.threadId,
            createdAt: Date()
        ))
        replyToMessage = nil

        // Fall back to conversationMembers when no incoming messages exist yet
        // (e.g., first message in a conversation), otherwise iOS sends phase-1 plaintext.
        let otherUser = otherUserId(from: messages)
            ?? conversationMembers.first(where: { $0.userId != currentUserId })?.userId
        let (content, iv) = await encrypt(plaintext: text, otherUserId: otherUser)
        let params = SendMessageParams(
            conversationId: conversationId, senderId: currentUserId,
            content: content, iv: iv, type: "text",
            replyToId: capturedReplyTo?.id, threadId: capturedReplyTo?.threadId
        )
        do {
            let sent = try await repository.sendMessage(params)
            // Realtime may have already inserted the real message before this returns
            if messages.contains(where: { $0.id == sent.id }) {
                messages.removeAll { $0.id == tempId }
            } else if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                messages[idx] = DecryptedMessage(
                    id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                    content: text, type: sent.type,
                    replyToId: capturedReplyTo?.id, threadId: capturedReplyTo?.threadId,
                    createdAt: sent.createdAt
                )
            }
        } catch {
            messages.removeAll { $0.id == tempId }
            replyToMessage = capturedReplyTo
            self.error = error.localizedDescription
        }
    }

    // MARK: - Send media

    func sendImageMessage(imageData: Data, mimeType: String) async {
        isSending = true
        defer { isSending = false }
        do {
            let url = try await uploadService.uploadImage(imageData, mimeType: mimeType, userId: currentUserId)
            let params = SendMessageParams(
                conversationId: conversationId, senderId: currentUserId,
                content: "", iv: nil, type: "image", mediaUrl: url, mediaMime: mimeType
            )
            let sent = try await repository.sendMessage(params)
            messages.append(DecryptedMessage(
                id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                content: "", type: "image", mediaUrl: url, createdAt: sent.createdAt
            ))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sendGifMessage(url: String) async {
        // Optimistic: GIF URL is already known, show immediately
        let tempId = UUID()
        messages.append(DecryptedMessage(
            id: tempId, conversationId: conversationId, senderId: currentUserId,
            content: "", type: "gif", mediaUrl: url, createdAt: Date()
        ))

        let params = SendMessageParams(
            conversationId: conversationId, senderId: currentUserId,
            content: "", iv: nil, type: "gif", mediaUrl: url, mediaMime: "image/gif"
        )
        do {
            let sent = try await repository.sendMessage(params)
            if messages.contains(where: { $0.id == sent.id }) {
                messages.removeAll { $0.id == tempId }
            } else if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                messages[idx] = DecryptedMessage(
                    id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                    content: "", type: "gif", mediaUrl: url, createdAt: sent.createdAt
                )
            }
        } catch {
            messages.removeAll { $0.id == tempId }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Delete

    func deleteMessage(id: UUID) async {
        do {
            try await repository.softDelete(messageId: id)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                let m = messages[idx]
                messages[idx] = DecryptedMessage(
                    id: m.id, conversationId: m.conversationId, senderId: m.senderId,
                    content: m.content, type: m.type, mediaUrl: m.mediaUrl,
                    replyToId: m.replyToId, threadId: m.threadId, editedAt: m.editedAt,
                    deletedAt: Date(), createdAt: m.createdAt, senderProfile: m.senderProfile
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Reactions

    func toggleReaction(messageId: UUID, emoji: String) {
        let groups = reactionsMap[messageId] ?? []
        let alreadyReacted = groups.first(where: { $0.emoji == emoji })?.reactedByMe ?? false

        // Optimistic update
        var updated = groups
        if alreadyReacted {
            updated = updated.map { g in
                g.emoji == emoji ? ReactionGroup(emoji: g.emoji, count: g.count - 1, reactedByMe: false) : g
            }.filter { $0.count > 0 }
        } else if let idx = updated.firstIndex(where: { $0.emoji == emoji }) {
            updated[idx] = ReactionGroup(emoji: emoji, count: updated[idx].count + 1, reactedByMe: true)
        } else {
            updated.append(ReactionGroup(emoji: emoji, count: 1, reactedByMe: true))
        }
        reactionsMap[messageId] = updated

        Task {
            do {
                if alreadyReacted {
                    try await repository.removeReaction(messageId: messageId, userId: currentUserId, emoji: emoji)
                } else {
                    try await repository.addReaction(messageId: messageId, userId: currentUserId, emoji: emoji)
                }
            } catch {
                // Roll back optimistic update on error
                await loadReactions()
            }
        }
    }

    // MARK: - Real-time

    private func startRealtime() {
        realtimeTask?.cancel()
        if let ch = pgChannel { Task { await supabase.removeChannel(ch) }; pgChannel = nil }
        if let ch = typingChannel { Task { await supabase.removeChannel(ch) }; typingChannel = nil }

        realtimeTask = Task {
            let pg = supabase.channel("chat-\(conversationId.uuidString)-\(UUID().uuidString)")
            pgChannel = pg
            let inserts = pg.postgresChange(
                InsertAction.self, schema: "public", table: "messages",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            let messageUpdates = pg.postgresChange(
                UpdateAction.self, schema: "public", table: "messages",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            let reactionInserts = pg.postgresChange(InsertAction.self, schema: "public", table: "message_reactions")
            let reactionDeletes = pg.postgresChange(DeleteAction.self, schema: "public", table: "message_reactions")
            let readInserts = pg.postgresChange(InsertAction.self, schema: "public", table: "message_reads")
            try? await pg.subscribeWithError()

            let tc = supabase.channel("typing:\(conversationId.uuidString.lowercased())")
            let typingStream = tc.broadcast(event: "typing")
            try? await tc.subscribeWithError()
            typingChannel = tc  // Set after subscription so broadcasts don't fire on unsubscribed channel

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in inserts {
                        // Skip own inserts — sendMessage() already handles the optimistic → confirmed swap
                        if event.record["sender_id"]?.stringValue == self.currentUserId.uuidString { continue }
                        await self.handleIncomingRealtimeMessage(event.record)
                    }
                }
                group.addTask {
                    for await event in messageUpdates {
                        // Skip own updates — deleteMessage() already mutates local state optimistically
                        if event.record["sender_id"]?.stringValue == self.currentUserId.uuidString { continue }
                        await self.handleMessageUpdate(event.record)
                    }
                }
                group.addTask { for await _ in reactionInserts { await self.loadReactionsForCurrentMessages() } }
                group.addTask { for await _ in reactionDeletes { await self.loadReactionsForCurrentMessages() } }
                group.addTask { for await _ in readInserts { await self.fetchReadStatus() } }
                group.addTask { for await payload in typingStream { await self.handleTyping(payload) } }
            }
        }
    }

    private func handleTyping(_ payload: JSONObject) async {
        // supabase-swift delivers the outer broadcast envelope; the user data is nested under "payload"
        let inner = payload["payload"]?.objectValue ?? payload
        guard
            let userId = inner["userId"]?.stringValue,
            let username = inner["username"]?.stringValue,
            let isTyping = inner["isTyping"]?.boolValue,
            userId.lowercased() != currentUserId.uuidString.lowercased()
        else { return }

        typingTimers[userId]?.cancel()
        typingTimers[userId] = nil

        if isTyping {
            if !typingUsernames.contains(username) { typingUsernames.append(username) }
            typingTimers[userId] = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.typingUsernames.removeAll { $0 == username } }
            }
        } else {
            typingUsernames.removeAll { $0 == username }
        }
    }

    // MARK: - Typing broadcast

    func notifyTyping() {
        typingDebounce?.cancel()
        if !isTyping {
            isTyping = true
            sendTypingEvent(true)
        }
        typingDebounce = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                self.isTyping = false
                self.sendTypingEvent(false)
            }
        }
    }

    func notifyStopTyping() {
        typingDebounce?.cancel()
        if isTyping {
            isTyping = false
            sendTypingEvent(false)
        }
    }

    private func sendTypingEvent(_ typing: Bool) {
        guard let channel = typingChannel else { return }
        Task {
            await channel.broadcast(
                event: "typing",
                message: [
                    "userId": .string(currentUserId.uuidString),
                    "username": .string(currentUsername),
                    "isTyping": .bool(typing)
                ]
            )
        }
    }

    // Parses the raw Realtime INSERT record into a DecryptedMessage without any network fetch.
    // Mirrors the web setQueryData approach: instant display, no round-trip.
    private func handleIncomingRealtimeMessage(_ record: [String: AnyJSON]) async {
        guard
            let idStr = record["id"]?.stringValue, let id = UUID(uuidString: idStr),
            let convIdStr = record["conversation_id"]?.stringValue, let convId = UUID(uuidString: convIdStr),
            let content = record["content"]?.stringValue,
            let type = record["type"]?.stringValue,
            let createdAtStr = record["created_at"]?.stringValue,
            let createdAt = Self.parseRealtimeDate(createdAtStr)
        else { return }

        guard !messages.contains(where: { $0.id == id }) else { return }

        let senderIdStr = record["sender_id"]?.stringValue
        let senderId = senderIdStr.flatMap(UUID.init(uuidString:))
        let iv = record["iv"]?.stringValue

        // Look up sender profile from already-loaded conversationMembers — no network needed
        let senderProfile = conversationMembers.first(where: { $0.userId == senderId })?.profile

        var decryptedContent = content
        if let sId = senderId, sId != currentUserId {
            decryptedContent = await decryptContent(content, iv: iv, otherUserId: sId)
        } else if iv == nil {
            decryptedContent = EncryptionService.decryptLegacy(content) ?? content
        }

        let msg = DecryptedMessage(
            id: id, conversationId: convId, senderId: senderId,
            content: decryptedContent, type: type,
            mediaUrl: record["media_url"]?.stringValue,
            replyToId: record["reply_to_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            threadId: record["thread_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            editedAt: record["edited_at"]?.stringValue.flatMap(Self.parseRealtimeDate),
            deletedAt: record["deleted_at"]?.stringValue.flatMap(Self.parseRealtimeDate),
            createdAt: createdAt,
            senderProfile: senderProfile
        )
        messages.append(msg)
        await markAndFetchReceipts()
    }

    private func handleMessageUpdate(_ record: [String: AnyJSON]) async {
        guard
            let idStr = record["id"]?.stringValue,
            let id = UUID(uuidString: idStr)
        else { return }

        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }

        let deletedAtStr = record["deleted_at"]?.stringValue
        let deletedAt = deletedAtStr.flatMap(Self.parseRealtimeDate)

        let m = messages[idx]
        messages[idx] = DecryptedMessage(
            id: m.id, conversationId: m.conversationId, senderId: m.senderId,
            content: m.content, type: m.type, mediaUrl: m.mediaUrl,
            replyToId: m.replyToId, threadId: m.threadId, editedAt: m.editedAt,
            deletedAt: deletedAt, createdAt: m.createdAt, senderProfile: m.senderProfile
        )
    }

    // Supabase Realtime sends timestamptz as ISO8601 with optional fractional seconds.
    // ISO8601DateFormatter does not handle fractional seconds by default, so we try both.
    private static let _dateParserFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let _dateParserPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseRealtimeDate(_ str: String) -> Date? {
        _dateParserFull.date(from: str) ?? _dateParserPlain.date(from: str)
    }

    // MARK: - Encryption helpers

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

    private func decryptAll(_ raw: [DbMessage], otherUserId: UUID?) async -> [DecryptedMessage] {
        var result: [DecryptedMessage] = []
        for msg in raw.reversed() {
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

    private func decryptContent(_ content: String, iv: String?, otherUserId: UUID) async -> String {
        do {
            let key = try await sharedKey(for: otherUserId)
            return try EncryptionService.decryptMessage(content: content, iv: iv, key: key)
        } catch {
            return EncryptionService.decryptLegacy(content) ?? content
        }
    }

    private func sharedKey(for otherUserId: UUID) async throws -> SymmetricKey {
        // 1. In-memory cache (fastest — no Keychain read)
        if let cached = derivedKeyCache { return cached }

        // 2. Keychain cache
        if let cached = try? KeyStore.loadDerivedKey(forConversation: conversationId) {
            derivedKeyCache = cached
            return cached
        }

        // 3. Derive: load identity key (cached in memory after first load), fetch peer's public key
        if identityPrivKeyCache == nil {
            identityPrivKeyCache = try KeyStore.loadIdentityKeyPair()
        }
        guard let myPrivKey = identityPrivKeyCache else {
            throw EncryptionService.Error.invalidJWK
        }

        // Decode only the x/y fields — web JWKs also contain ext:Bool and key_ops:[String]
        // which break [String:String] decoding; Codable ignores unknown fields in a struct.
        struct DeviceKeyRow: Decodable {
            struct JWKCoords: Decodable { let x: String; let y: String }
            let identityKey: JWKCoords?
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

        guard let coords = deviceRow.identityKey else { throw EncryptionService.Error.invalidJWK }
        let theirKey = try EncryptionService.publicKeyFromJWK(["x": coords.x, "y": coords.y])
        let derived = try EncryptionService.deriveSharedKey(myPrivateKey: myPrivKey, theirPublicKey: theirKey)
        derivedKeyCache = derived
        try? KeyStore.storeDerivedKey(derived, forConversation: conversationId)
        return derived
    }

    private func otherUserId(from messages: [DecryptedMessage]) -> UUID? {
        messages.first(where: { $0.senderId != currentUserId })?.senderId
    }

    private func otherUserId(from raw: [DbMessage]) -> UUID? {
        raw.first(where: { $0.senderId != currentUserId })?.senderId
    }
}
