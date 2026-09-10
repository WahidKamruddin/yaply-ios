import Supabase
import CryptoKit
import Foundation
import Realtime
import SwiftUI

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
    /// Pinned message ids, most-recently-pinned first.
    private(set) var pinnedMessageIds: [UUID] = []

    // Read receipts
    private(set) var readByOtherSet: Set<UUID> = []
    private var markedReadIds: Set<UUID> = []

    // Group info
    private(set) var conversationMembers: [MemberSummary] = []
    private(set) var isGroupConversation = false
    private(set) var groupName: String?

    // My own conversation_members.request_state — 'accepted' unless this is a
    // pending/declined DM (see Friends System docs). Drives whether ChatView shows
    // MessageInputView or MessageRequestBarView.
    private(set) var myRequestState: String = "accepted"

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

    // In-memory identity-key cache — avoids a Keychain read on every message decrypt.
    // (No per-conversation derived-key cache under v2 — every message has its own key.)

    init(conversationId: UUID, currentUserId: UUID) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
    }

    // MARK: - Lifecycle

    func onAppear() async {
        isLoading = true
        async let msgs: Void = loadMessages()
        async let conv: Void = loadConversationInfo()
        async let reqState: Void = loadMyRequestState()
        async let pins: Void = loadPins()
        await msgs
        await conv
        await reqState
        await pins
        isLoading = false
        try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: currentUserId)
        await markAndFetchReceipts()
        startRealtime()
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
            let ids = raw.map(\.id)
            async let decrypted = decryptAll(raw)
            async let rawReactions = repository.fetchReactions(messageIds: ids)
            messages = await decrypted
            if let reactions = try? await rawReactions {
                reactionsMap = buildReactionGroups(from: reactions)
            }
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
            let ids = raw.map(\.id)
            async let decrypted = decryptAll(raw)
            async let rawReactions = repository.fetchReactions(messageIds: ids)
            let older = await decrypted
            messages = older + messages
            if let reactions = try? await rawReactions {
                reactionsMap = buildReactionGroups(from: reactions)
            }
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
            let name: String?
            let conversationMembers: [MemberRow]
            enum CodingKeys: String, CodingKey {
                case type, name; case conversationMembers = "conversation_members"
            }
        }
        guard let info: ConvInfo = try? await supabase
            .from("conversations")
            .select("type, name, conversation_members(user_id, role, profiles(id, username, display_name, avatar_url, is_online, last_seen_at, created_at, updated_at))")
            .eq("id", value: conversationId.uuidString)
            .single()
            .execute()
            .value
        else { return }

        isGroupConversation = info.type == "group"
        groupName = info.name
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

    func loadMyRequestState() async {
        struct RequestStateRow: Decodable {
            let requestState: String
            enum CodingKeys: String, CodingKey { case requestState = "request_state" }
        }
        guard let row: RequestStateRow = try? await supabase
            .from("conversation_members")
            .select("request_state")
            .eq("conversation_id", value: conversationId.uuidString)
            .eq("user_id", value: currentUserId.uuidString)
            .single()
            .execute()
            .value
        else { return }
        myRequestState = row.requestState
    }

    // Called locally right after Accept/Decline succeeds server-side, so the
    // composer swaps immediately without waiting on a re-fetch.
    func setMyRequestState(_ state: String) {
        myRequestState = state
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

        do {
            // Registration is single-flight — safe to call even if already done.
            try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: currentUserId)

            let sent: DbMessage
            if let sealed = await EnvelopeEncryption.encryptForMembers(
                plaintext: text, memberUserIds: memberIdsForEncryption(), repository: repository
            ) {
                let params = SendMessageWithEnvelopesParams(
                    pConversationId: conversationId, pContent: sealed.content, pIv: sealed.iv,
                    pEnvelopes: sealed.envelopes, pType: "text",
                    pReplyToId: capturedReplyTo?.id, pThreadId: capturedReplyTo?.threadId,
                    pMediaUrl: nil, pMediaMime: nil
                )
                sent = try await repository.sendMessageWithEnvelopes(params)
            } else {
                // Phase-1 fallback: some member has zero registered devices yet.
                let params = SendMessageParams(
                    conversationId: conversationId, senderId: currentUserId,
                    content: Data(text.utf8).base64EncodedString(), iv: nil, type: "text",
                    replyToId: capturedReplyTo?.id, threadId: capturedReplyTo?.threadId
                )
                sent = try await repository.sendMessage(params)
            }

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

    // Every conversation member, including the sender — omitting the sender's own
    // id would mean the sender's other devices (and this one, after a reload)
    // can't read the message back, the original single-slot-era bug.
    private func memberIdsForEncryption() -> [UUID] {
        var ids = Set(conversationMembers.map(\.userId))
        if ids.isEmpty, let other = otherUserId(from: messages) {
            ids.insert(other)
        }
        ids.insert(currentUserId)
        return Array(ids)
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

    /// Send a system/Genmoji/Markup sticker the user dropped, pasted, or picked
    /// from the iOS keyboard. Stored as a transparent PNG in the `media` bucket
    /// and sent unencrypted (`content: ""`, `iv: nil`, `type: "sticker"`) — same
    /// path as image/gif, never the envelope RPC.
    func sendStickerMessage(image: UIImage) async {
        let normalized = image.resized(maxDimension: 512)
        guard let png = normalized.pngData() else {
            self.error = "Couldn't read that sticker."
            return
        }

        let tempId = UUID()
        messages.append(DecryptedMessage(
            id: tempId, conversationId: conversationId, senderId: currentUserId,
            content: "", type: "sticker", mediaUrl: nil, createdAt: Date()
        ))

        do {
            let url = try await uploadService.uploadImage(
                png, mimeType: "image/png", ext: "png", userId: currentUserId
            )
            let params = SendMessageParams(
                conversationId: conversationId, senderId: currentUserId,
                content: "", iv: nil, type: "sticker", mediaUrl: url, mediaMime: "image/png"
            )
            let sent = try await repository.sendMessage(params)
            if messages.contains(where: { $0.id == sent.id }) {
                messages.removeAll { $0.id == tempId }
            } else if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                messages[idx] = DecryptedMessage(
                    id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                    content: "", type: "sticker", mediaUrl: url, createdAt: sent.createdAt
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

    /// The single emoji this user currently has on a message, if any.
    func myReaction(for messageId: UUID) -> String? {
        reactionsMap[messageId]?.first(where: { $0.reactedByMe })?.emoji
    }

    /// One reaction per user (Messenger / Instagram): picking `emoji` replaces any
    /// existing reaction; picking the one already set removes it.
    func setReaction(messageId: UUID, emoji: String) {
        let groups = reactionsMap[messageId] ?? []
        let mine = groups.first(where: { $0.reactedByMe })?.emoji
        let clearing = (mine == emoji)

        // Optimistic: drop my current reaction, then add the new one unless toggling off.
        var updated = groups.compactMap { g -> ReactionGroup? in
            guard g.reactedByMe else { return g }
            let c = g.count - 1
            return c > 0 ? ReactionGroup(emoji: g.emoji, count: c, reactedByMe: false) : nil
        }
        if !clearing {
            if let idx = updated.firstIndex(where: { $0.emoji == emoji }) {
                updated[idx] = ReactionGroup(emoji: emoji, count: updated[idx].count + 1, reactedByMe: true)
            } else {
                updated.append(ReactionGroup(emoji: emoji, count: 1, reactedByMe: true))
            }
        }
        reactionsMap[messageId] = updated

        Task {
            do {
                try await repository.removeAllReactions(messageId: messageId, userId: currentUserId)
                if !clearing {
                    try await repository.addReaction(messageId: messageId, userId: currentUserId, emoji: emoji)
                }
            } catch {
                await loadReactions()
            }
        }
    }

    // MARK: - Pins

    func isPinned(_ messageId: UUID) -> Bool { pinnedMessageIds.contains(messageId) }

    /// The most-recently-pinned message that is currently loaded, for the banner.
    var topPinnedMessage: DecryptedMessage? {
        for id in pinnedMessageIds {
            if let m = messages.first(where: { $0.id == id }) { return m }
        }
        return nil
    }

    func loadPins() async {
        guard let ids = try? await repository.fetchPinnedMessageIds(conversationId: conversationId) else { return }
        pinnedMessageIds = ids
    }

    func togglePin(messageId: UUID) {
        let wasPinned = pinnedMessageIds.contains(messageId)
        if wasPinned {
            pinnedMessageIds.removeAll { $0 == messageId }
        } else {
            pinnedMessageIds.insert(messageId, at: 0)
        }
        Task {
            do {
                if wasPinned {
                    try await repository.unpinMessage(messageId: messageId, conversationId: conversationId)
                } else {
                    try await repository.pinMessage(messageId: messageId, conversationId: conversationId, userId: currentUserId)
                }
            } catch {
                await loadPins()
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
            let pinInserts = pg.postgresChange(
                InsertAction.self, schema: "public", table: "pinned_messages",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            let pinDeletes = pg.postgresChange(DeleteAction.self, schema: "public", table: "pinned_messages")
            let readInserts = pg.postgresChange(InsertAction.self, schema: "public", table: "message_reads")
            let profileUpdates = pg.postgresChange(UpdateAction.self, schema: "public", table: "profiles")
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
                group.addTask { for await _ in pinInserts { await self.loadPins() } }
                group.addTask { for await _ in pinDeletes { await self.loadPins() } }
                group.addTask { for await _ in readInserts { await self.fetchReadStatus() } }
                group.addTask { for await event in profileUpdates { await self.handleProfileUpdate(event.record) } }
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
        let encV = record["enc_v"]?.intValue

        // Look up sender profile from already-loaded conversationMembers — no network needed
        let senderProfile = conversationMembers.first(where: { $0.userId == senderId })?.profile

        let dbMsg = DbMessage(
            id: id, conversationId: convId, senderId: senderId, content: content, iv: iv,
            encV: encV, type: type, mediaUrl: record["media_url"]?.stringValue, mediaMime: nil,
            replyToId: record["reply_to_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            threadId: record["thread_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            editedAt: record["edited_at"]?.stringValue.flatMap(Self.parseRealtimeDate),
            deletedAt: record["deleted_at"]?.stringValue.flatMap(Self.parseRealtimeDate),
            createdAt: createdAt, senderProfile: nil
        )
        let (decryptedContent, failed) = await decryptDbMessage(dbMsg)

        let msg = DecryptedMessage(
            id: id, conversationId: convId, senderId: senderId,
            content: decryptedContent, type: type,
            mediaUrl: record["media_url"]?.stringValue,
            replyToId: dbMsg.replyToId,
            threadId: dbMsg.threadId,
            editedAt: dbMsg.editedAt,
            deletedAt: dbMsg.deletedAt,
            createdAt: createdAt,
            senderProfile: senderProfile,
            decryptFailed: failed
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
            deletedAt: deletedAt, createdAt: m.createdAt, senderProfile: m.senderProfile,
            decryptFailed: m.decryptFailed
        )
    }

    // Keeps the in-chat "Online"/"Offline" header live — patches just the changed
    // member's profile in place rather than re-fetching the whole conversation.
    private func handleProfileUpdate(_ record: [String: AnyJSON]) async {
        guard
            let idStr = record["id"]?.stringValue, let id = UUID(uuidString: idStr),
            let idx = conversationMembers.firstIndex(where: { $0.userId == id })
        else { return }

        var profile = conversationMembers[idx].profile
        if let isOnline = record["is_online"]?.boolValue {
            profile.isOnline = isOnline
        }
        if let lastSeenStr = record["last_seen_at"]?.stringValue,
           let lastSeen = Self.parseRealtimeDate(lastSeenStr) {
            profile.lastSeenAt = lastSeen
        }
        conversationMembers[idx].profile = profile
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

    // MARK: - Encryption helpers (v2 — branches on enc_v first, then iv)

    private func decryptAll(_ raw: [DbMessage]) async -> [DecryptedMessage] {
        var result: [DecryptedMessage] = []
        for msg in raw.reversed() {
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

    // enc_v == 2 → envelope path; no envelope for this device ⇒ permanent, honest
    // failure (never falls through to phase-1 decoding). enc_v == nil && iv == nil
    // → phase-1 plain base64. Anything else → failure. Media/system rows have
    // enc_v == nil and iv == nil too, so they resolve via the phase-1 branch, which
    // is a no-op for their empty `content`.
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


    private func otherUserId(from messages: [DecryptedMessage]) -> UUID? {
        messages.first(where: { $0.senderId != currentUserId })?.senderId
    }
}
