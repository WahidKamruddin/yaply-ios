import Supabase
import CryptoKit
import Foundation
import Realtime
import SwiftUI
import Kingfisher

@Observable
@MainActor
final class ChatViewModel {
    private(set) var messages: [DecryptedMessage] = [] {
        didSet { rebuildLayout() }
    }

    /// Date separators, bubble positions, reply index, thread counts and the
    /// last-own-message id, all derived from `messages`.
    ///
    /// Rebuilt here -- once per mutation -- rather than inside `ChatView.body`,
    /// where it was being recomputed on every scroll frame and cost O(n^2)
    /// because the reply lookup and thread counts were per-row linear scans.
    private(set) var layout = MessageListLayout()

    private func rebuildLayout() {
        layout = MessageListLayout.build(
            messages,
            isGroupConversation: isGroupConversation,
            currentUserId: currentUserId
        )
    }

    /// O(1) reply lookup, replacing `messages.first { $0.id == rid }` per row.
    func message(id: UUID) -> DecryptedMessage? { layout.messagesById[id] }
    private(set) var isLoading = false
    /// In-flight guard for `loadOlderMessages` — see the note there.
    private var isLoadingOlder = false
    private(set) var isSending = false
    var error: String?
    var replyToMessage: DecryptedMessage?
    // Holds user ids (not display names) so callers can reliably look up the
    // typing member's profile — display names collide and aren't unique keys.
    private(set) var typingUserIds: [String] = []
    private(set) var reactionsMap: [UUID: [ReactionGroup]] = [:]
    /// Pinned message ids, most-recently-pinned first.
    private(set) var pinnedMessageIds: [UUID] = []

    // Read receipts
    private(set) var readByOtherSet: Set<UUID> = []
    private var markedReadIds: Set<UUID> = []

    // Group info
    private(set) var conversationMembers: [MemberSummary] = []
    // `loadConversationInfo` can resolve this after the first page of messages
    // has already landed, and it decides whether new-speaker spacing applies —
    // so the derived layout has to be rebuilt when it flips.
    private(set) var isGroupConversation = false {
        didSet { if oldValue != isGroupConversation { rebuildLayout() } }
    }
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
    private var presenceChannel: RealtimeChannelV2?
    private var typingTimers: [String: Task<Void, Never>] = [:]
    private var reconnectToken: UUID?
    private var isTyping = false
    private var typingDebounce: Task<Void, Never>?
    private var receiptsTask: Task<Void, Never>?
    /// `created_at` of the newest row the initial page fetch returned — the
    /// catch-up after the first subscribe fetches only what landed after it.
    private var newestFetchedAt: Date?

    // In-memory identity-key cache — avoids a Keychain read on every message decrypt.
    // (No per-conversation derived-key cache under v2 — every message has its own key.)

    init(conversationId: UUID, currentUserId: UUID) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
    }

    // MARK: - Lifecycle

    func onAppear() async {
        isLoading = true
        let initialLoad = Task {
            async let msgs: Void = loadMessages()
            async let conv: Void = loadConversationInfo()
            async let reqState: Void = loadMyRequestState()
            async let pins: Void = loadPins()
            await msgs
            await conv
            await reqState
            await pins
        }
        // Subscribe alongside the first fetch, not after it. This used to wait for
        // every load, registration and the receipts round-trips before joining, and
        // anything sent in that window (seconds on cellular) never appeared until the
        // next reconnect. The realtime task closes the fetch→join gap itself.
        startRealtime(initialLoad: initialLoad)
        await initialLoad.value
        isLoading = false
        // Warm the device list so the first send is a single round-trip.
        DeviceListCache.prefetch(userIds: memberIdsForEncryption(), repository: repository)
        await markAndFetchReceipts()
    }

    func onDisappear() {
        receiptsTask?.cancel()
        receiptsTask = nil
        sendTypingEvent(false)
        typingDebounce?.cancel()
        typingTimers.values.forEach { $0.cancel() }
        typingTimers = [:]
        stopRealtime()
    }

    // MARK: - Message loading + decryption

    func loadMessages() async {
        do {
            let (raw, cursor) = try await repository.fetchMessages(conversationId: conversationId)
            nextCursor = cursor
            hasMore = cursor != nil
            newestFetchedAt = raw.first?.createdAt
            let ids = raw.map(\.id)
            async let decrypted = decryptAll(raw)
            async let rawReactions = repository.fetchReactions(messageIds: ids)
            // Merged, not assigned: realtime is already live while this page loads, and
            // a reconnect catch-up can land first too.
            merge(await decrypted)
            if let reactions = try? await rawReactions {
                reactionsMap = buildReactionGroups(from: reactions)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadOlderMessages() async {
        // The pagination spinner sits at the head of a LazyVStack, so its
        // `.onAppear` can fire again while the previous page is still in
        // flight -- `nextCursor` isn't advanced until the fetch returns, so
        // without this guard the same page gets prepended twice.
        guard hasMore, !isLoadingOlder, let cursor = nextCursor else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
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

    /// Messages kept once the user is back at the bottom, and the count that
    /// triggers a trim. The gap stops a user hovering near the bottom from
    /// trimming on every page.
    private static let retainedMessageCount = 150
    private static let trimThreshold = 250

    /// Drops loaded history above the newest `retainedMessageCount` messages.
    /// `LazyVStack` never releases a row once built, so every page scrolled into
    /// view — and every image in it — stayed in memory for the life of the chat.
    /// Pagination resumes from the oldest kept message, so scrolling up reloads
    /// what was dropped. Call only while the user is at the bottom, where the
    /// removed rows are far off screen. Returns whether anything was trimmed.
    @discardableResult
    func trimHistoryIfNeeded() -> Bool {
        guard messages.count > Self.trimThreshold, !isLoadingOlder else { return false }
        let kept = Array(messages.suffix(Self.retainedMessageCount))
        guard let oldestKept = kept.first else { return false }
        let dropped = Set(messages.prefix(messages.count - kept.count).map(\.id))
        messages = kept
        reactionsMap = reactionsMap.filter { !dropped.contains($0.key) }
        readByOtherSet.subtract(dropped)
        nextCursor = oldestKept.createdAt
        hasMore = true
        return true
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

        // Extracted from plaintext before encryption — mention targeting is the
        // one piece of this send that travels unencrypted, since the server
        // needs it to fan out push/badge notifications. DMs never carry
        // mentions. See ../CLAUDE.md's mentions section.
        let mentions: (mentionedUserIds: [UUID], mentionsEveryone: Bool) = isGroupConversation
            ? Mentions.extractMentions(
                text: text,
                members: conversationMembers.map { Mentions.Candidate(userId: $0.userId, username: $0.profile.username) },
                senderId: currentUserId
            )
            : ([], false)

        do {
            let sendStart = ContinuousClock.now
            // Registration is single-flight — safe to call even if already done.
            try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: currentUserId)

            let sent: DbMessage
            let sealStart = ContinuousClock.now
            let sealed = await EnvelopeEncryption.encryptForMembers(
                plaintext: text, memberUserIds: memberIdsForEncryption(), repository: repository
            )
            let sealMs = Self.ms(since: sealStart)
            if let sealed {
                let params = SendMessageWithEnvelopesParams(
                    pConversationId: conversationId, pContent: sealed.content, pIv: sealed.iv,
                    pEnvelopes: sealed.envelopes, pType: "text",
                    pReplyToId: capturedReplyTo?.id, pThreadId: capturedReplyTo?.threadId,
                    pMediaUrl: nil, pMediaMime: nil,
                    pMentionedUserIds: mentions.mentionedUserIds, pMentionsEveryone: mentions.mentionsEveryone
                )
                sent = try await repository.sendMessageWithEnvelopes(params)
            } else {
                // Phase-1 fallback: some member has zero registered devices yet.
                let params = SendMessageParams(
                    conversationId: conversationId, senderId: currentUserId,
                    content: Data(text.utf8).base64EncodedString(), iv: nil, type: "text",
                    replyToId: capturedReplyTo?.id, threadId: capturedReplyTo?.threadId,
                    mentionedUserIds: mentions.mentionedUserIds, mentionsEveryone: mentions.mentionsEveryone
                )
                sent = try await repository.sendMessage(params)
            }
            print("[Perf] sent \(sent.id): total \(Self.ms(since: sendStart))ms, seal \(sealMs)ms (device lookup + wrap)")

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

    /// `pixelSize` is the size actually encoded, stamped onto the URL as an
    /// `#ar=` fragment so the receiving bubble can reserve the right height
    /// before the image has downloaded. Inert for Storage; ignored by clients
    /// that don't read it.
    func sendImageMessage(imageData: Data, mimeType: String, pixelSize: CGSize = .zero) async {
        isSending = true
        defer { isSending = false }

        // Optimistic: the bubble used to appear only after the upload and the
        // insert both finished, so a photo looked like it sent seconds late. The
        // temp bubble draws the bytes we already hold, under a local key that
        // never reaches the network, at its final aspect ratio.
        let tempId = UUID()
        let localKey = MediaAspectRatio.annotate("yaply-local://image/\(tempId.uuidString)", pixelSize: pixelSize)
        Self.seedImageCache(imageData, forKey: localKey)
        messages.append(DecryptedMessage(
            id: tempId, conversationId: conversationId, senderId: currentUserId,
            content: "", type: "image", mediaUrl: localKey, createdAt: Date()
        ))

        do {
            let uploaded = try await uploadService.uploadImage(imageData, mimeType: mimeType, userId: currentUserId)
            let url = MediaAspectRatio.annotate(uploaded, pixelSize: pixelSize)
            // We just encoded these exact bytes; without this the bubble turns
            // straight around and downloads them back from Storage to draw the
            // message the sender is already looking at.
            Self.seedImageCache(imageData, forKey: url)
            let params = SendMessageParams(
                conversationId: conversationId, senderId: currentUserId,
                content: "", iv: nil, type: "image", mediaUrl: url, mediaMime: mimeType
            )
            let sent = try await repository.sendMessage(params)
            let confirmed = DecryptedMessage(
                id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                content: "", type: "image", mediaUrl: url, createdAt: sent.createdAt
            )
            if messages.contains(where: { $0.id == sent.id }) {
                messages.removeAll { $0.id == tempId }
            } else if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                messages[idx] = confirmed
            } else {
                messages.append(confirmed)
            }
        } catch {
            messages.removeAll { $0.id == tempId }
            self.error = error.localizedDescription
        }
        try? await ImageCache.default.removeImage(forKey: localKey)
    }

    /// Puts freshly uploaded bytes into Kingfisher's cache under the URL the
    /// bubble will ask for, so a just-sent image renders from memory instead of
    /// making a round-trip for something we already have.
    ///
    /// Stored as the *original*: the bubble applies a downsampling processor, and
    /// Kingfisher will derive the processed variant from a cached original
    /// without hitting the network.
    private static func seedImageCache(_ data: Data, forKey key: String) {
        guard let image = KFCrossPlatformImage(data: data) else { return }
        ImageCache.default.store(
            image,
            original: data,
            forKey: key,
            toDisk: true
        )
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
        guard let sticker = await MediaEncoding.stickerPNG(image) else {
            self.error = "Couldn't read that sticker."
            return
        }
        let png = sticker.data

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

    /// Send a recorded voice message. Uploaded as an `.m4a` to the `media`
    /// bucket and sent unencrypted (`type: "voice"`, `content: ""`), same path
    /// as image/gif/sticker — never the envelope RPC.
    func sendVoiceMessage(fileURL: URL) async {
        let tempId = UUID()
        messages.append(DecryptedMessage(
            id: tempId, conversationId: conversationId, senderId: currentUserId,
            content: "", type: "voice", mediaUrl: nil, createdAt: Date()
        ))

        defer { try? FileManager.default.removeItem(at: fileURL) }
        do {
            let data = try Data(contentsOf: fileURL)
            let url = try await uploadService.uploadFile(
                data, filename: "voice-message.m4a", mimeType: "audio/mp4", userId: currentUserId
            )
            let params = SendMessageParams(
                conversationId: conversationId, senderId: currentUserId,
                content: "", iv: nil, type: "voice", mediaUrl: url, mediaMime: "audio/mp4"
            )
            let sent = try await repository.sendMessage(params)
            if messages.contains(where: { $0.id == sent.id }) {
                messages.removeAll { $0.id == tempId }
            } else if let idx = messages.firstIndex(where: { $0.id == tempId }) {
                messages[idx] = DecryptedMessage(
                    id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                    content: "", type: "voice", mediaUrl: url, createdAt: sent.createdAt
                )
            }
        } catch {
            messages.removeAll { $0.id == tempId }
            self.error = error.localizedDescription
        }
    }

    /// Send an arbitrary file attachment (`type: "file"`). Web renders this as a
    /// download link. Not E2E encrypted.
    func sendFileMessage(data: Data, filename: String, mimeType: String) async {
        isSending = true
        defer { isSending = false }
        do {
            let url = try await uploadService.uploadFile(
                data, filename: filename, mimeType: mimeType, userId: currentUserId
            )
            let params = SendMessageParams(
                conversationId: conversationId, senderId: currentUserId,
                content: "", iv: nil, type: "file", mediaUrl: url, mediaMime: mimeType
            )
            let sent = try await repository.sendMessage(params)
            messages.append(DecryptedMessage(
                id: sent.id, conversationId: sent.conversationId, senderId: sent.senderId,
                content: "", type: "file", mediaUrl: url, createdAt: sent.createdAt
            ))
        } catch {
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

    /// Every emoji this user currently has on a message. A user may hold several
    /// simultaneous reactions on one message — matches web, where the schema
    /// (`message_reactions` PK `(message_id, user_id, emoji)`) already allows it.
    func myReactions(for messageId: UUID) -> Set<String> {
        Set((reactionsMap[messageId] ?? []).filter(\.reactedByMe).map(\.emoji))
    }

    /// Toggles a single emoji for this user, independent of any other reaction
    /// they already hold on the message.
    func toggleReaction(messageId: UUID, emoji: String) {
        var groups = reactionsMap[messageId] ?? []
        let alreadyReacted = groups.contains { $0.emoji == emoji && $0.reactedByMe }

        // Optimistic update of just this emoji's group; every other group is untouched.
        if let idx = groups.firstIndex(where: { $0.emoji == emoji }) {
            let g = groups[idx]
            let count = alreadyReacted ? g.count - 1 : g.count + 1
            if count <= 0 {
                groups.remove(at: idx)
            } else {
                groups[idx] = ReactionGroup(emoji: emoji, count: count, reactedByMe: !alreadyReacted)
            }
        } else {
            groups.append(ReactionGroup(emoji: emoji, count: 1, reactedByMe: true))
        }
        reactionsMap[messageId] = groups

        Task {
            do {
                if alreadyReacted {
                    try await repository.removeReaction(messageId: messageId, userId: currentUserId, emoji: emoji)
                } else {
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

    /// `initialLoad` is the first page fetch from `onAppear`, running concurrently.
    /// Once joined, the task waits for it and then fetches only what arrived since,
    /// because the fetch's snapshot can predate the join.
    func startRealtime(refetchOnSubscribe: Bool = false, initialLoad: Task<Void, Never>? = nil) {
        realtimeTask?.cancel()
        RealtimeConnectionMonitor.remove(pgChannel); pgChannel = nil
        RealtimeConnectionMonitor.remove(typingChannel); typingChannel = nil
        RealtimeConnectionMonitor.remove(presenceChannel); presenceChannel = nil

        let label = "chat-\(conversationId.uuidString)"
        if reconnectToken == nil {
            reconnectToken = RealtimeConnectionMonitor.shared.register(label: label) { [weak self] in
                self?.startRealtime(refetchOnSubscribe: true)
            }
        }

        realtimeTask = Task {
            let pg = await RealtimeConnectionMonitor.channel("chat-\(conversationId.uuidString)-\(UUID().uuidString)")
            guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(pg); return }
            pgChannel = pg
            let inserts = pg.postgresChange(
                InsertAction.self, schema: "public", table: "messages",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            let messageUpdates = pg.postgresChange(
                UpdateAction.self, schema: "public", table: "messages",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            // Filtered server-side by message_reactions.conversation_id (migration
            // 20260927000002). Deletes can't be filtered by Realtime, so they stay
            // unfiltered and are matched against the loaded messages below.
            let reactionInserts = pg.postgresChange(
                InsertAction.self, schema: "public", table: "message_reactions",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            let reactionDeletes = pg.postgresChange(DeleteAction.self, schema: "public", table: "message_reactions")
            let pinInserts = pg.postgresChange(
                InsertAction.self, schema: "public", table: "pinned_messages",
                filter: .eq("conversation_id", value: conversationId.uuidString)
            )
            let pinDeletes = pg.postgresChange(DeleteAction.self, schema: "public", table: "pinned_messages")
            let readInserts = pg.postgresChange(InsertAction.self, schema: "public", table: "message_reads")
            await RealtimeConnectionMonitor.subscribe(pg, label: label)

            // Catch up *after* the subscription is live, never before: an event landing
            // during the refetch is then either delivered live or included in the fetch.
            // Refetching first would lose exactly that window.
            if refetchOnSubscribe {
                await catchUpAfterReconnect()
            } else if let initialLoad {
                // Events arriving meanwhile are buffered by the streams above and
                // de-duplicated by id when the group below drains them.
                await initialLoad.value
                guard !Task.isCancelled else { return }
                await mergeMessagesSinceInitialLoad()
            }

            // Message events are consumed from here on regardless of the typing channel.
            // Typing used to be subscribed *before* this group started, so a typing
            // channel that never joined meant no message ever arrived live.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await RealtimeConnectionMonitor.watch(pg, label: label) { [weak self] in
                        self?.startRealtime(refetchOnSubscribe: true)
                    }
                }
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
                // `message_reads` has no conversation_id and reaction deletes
                // can't be filtered, so those arrive for the whole database and
                // are gated on the row naming a loaded message. Only that one
                // message is refetched — every event used to refetch reactions
                // for every loaded message id.
                group.addTask {
                    for await event in reactionInserts {
                        guard let id = await self.loadedMessageId(event.record) else { continue }
                        await self.reloadReactions(for: id)
                    }
                }
                group.addTask {
                    for await event in reactionDeletes {
                        guard let id = await self.loadedMessageId(event.oldRecord) else { continue }
                        await self.reloadReactions(for: id)
                    }
                }
                group.addTask { for await _ in pinInserts { await self.loadPins() } }
                group.addTask {
                    // Delete events carry only the primary key, which for
                    // pinned_messages includes conversation_id.
                    for await event in pinDeletes
                    where event.oldRecord["conversation_id"]?.stringValue == self.conversationId.uuidString {
                        await self.loadPins()
                    }
                }
                // The insert itself says who read what, so it's applied in place
                // rather than re-querying read status for every own message.
                group.addTask {
                    for await event in readInserts { await self.applyReadReceipt(event.record) }
                }
                group.addTask { await self.runTypingChannel() }
                group.addTask { await self.runPresenceChannel() }
            }
        }
    }

    // `typing:<conversation id>` is a fixed topic (web's useTypingIndicator listens on the
    // same one), so it goes through the monitor's channel()/remove() to avoid colliding
    // with its own previous instance. Non-critical: a failure here must never hold up
    // message delivery or trigger a global reconnect sweep.
    private func runTypingChannel() async {
        let tc = await RealtimeConnectionMonitor.channel("typing:\(conversationId.uuidString.lowercased())")
        guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(tc); return }
        let typingStream = tc.broadcast(event: "typing")
        await RealtimeConnectionMonitor.subscribe(tc, label: "typing-\(conversationId.uuidString)", critical: false)
        guard !Task.isCancelled else {
            RealtimeConnectionMonitor.remove(tc)
            return
        }
        typingChannel = tc  // Set after subscription so broadcasts don't fire on unsubscribed channel
        for await payload in typingStream { await handleTyping(payload) }
    }

    // The header's online/offline state, filtered to this conversation's other
    // members. It used to be an unfiltered `profiles` binding on the main channel,
    // so every presence heartbeat in the database reached every open chat. A
    // separate channel because the members are only known once the first load
    // has finished, and the main channel joins before that. Non-critical, like
    // typing: a failure here must never hold up message delivery.
    private func runPresenceChannel() async {
        let memberIds = conversationMembers.map(\.userId).filter { $0 != currentUserId }
        guard !memberIds.isEmpty, memberIds.count <= 100 else { return }
        let ch = await RealtimeConnectionMonitor.channel("chat-presence-\(conversationId.uuidString)-\(UUID().uuidString)")
        guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(ch); return }
        presenceChannel = ch
        let updates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "profiles",
            filter: .in("id", values: memberIds)
        )
        await RealtimeConnectionMonitor.subscribe(ch, label: "chat-presence-\(conversationId.uuidString)", critical: false)
        for await event in updates { await handleProfileUpdate(event.record) }
    }

    func stopRealtime() {
        RealtimeConnectionMonitor.shared.unregister(reconnectToken)
        reconnectToken = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        RealtimeConnectionMonitor.remove(pgChannel); pgChannel = nil
        RealtimeConnectionMonitor.remove(typingChannel); typingChannel = nil
        RealtimeConnectionMonitor.remove(presenceChannel); presenceChannel = nil
    }

    // Everything that could have changed while the socket was down. Resubscribing alone
    // only delivers *future* events, so without this the chat reattaches and keeps
    // showing whatever it had before the interruption.
    private func catchUpAfterReconnect() async {
        await mergeLatestMessages()
        await loadPins()
        await loadReactionsForCurrentMessages()
        await fetchReadStatus()
        await loadMyRequestState()
    }

    // Merges the newest page into `messages` instead of replacing it, so pages the user
    // scrolled in via loadOlderMessages() survive and the scroll position is kept.
    // `nextCursor`/`hasMore` are deliberately left alone for the same reason.
    //
    // Refetched rows replace their local counterparts, which is what lands edits and the
    // deleted_at flips that arrived while offline. Optimistic sends still in flight keep
    // their temp id (not present server-side) and so survive untouched; if the insert has
    // already landed, sendMessage's completion path resolves the brief duplicate.
    private func mergeLatestMessages() async {
        guard let (raw, _) = try? await repository.fetchMessages(conversationId: conversationId) else { return }
        merge(await decryptAll(raw))
        await markAndFetchReceipts()
    }

    /// Closes the gap between the initial page's snapshot and the channel joining.
    /// Usually returns nothing, so it costs one small query rather than the full
    /// page + envelopes + reactions a reconnect catch-up pays.
    private func mergeMessagesSinceInitialLoad() async {
        guard let since = newestFetchedAt else {
            // Empty conversation, or the first fetch failed.
            await mergeLatestMessages()
            return
        }
        guard let raw = try? await repository.fetchMessagesSince(conversationId: conversationId, after: since),
              !raw.isEmpty
        else { return }
        // fetchMessagesSince caps at 20; more than that is a full page's worth.
        if raw.count >= 20 {
            await mergeLatestMessages()
            return
        }
        merge(await decryptAll(raw))
        scheduleReceipts()
    }

    /// Fetched rows replace their local counterparts (edits, deleted_at flips);
    /// everything else, including in-flight optimistic sends, is kept. Tie-break on
    /// id so messages sharing a timestamp keep a stable order rather than shuffling.
    private func merge(_ fresh: [DecryptedMessage]) {
        guard !messages.isEmpty else {
            messages = fresh
            return
        }
        var byId: [UUID: DecryptedMessage] = [:]
        for message in messages { byId[message.id] = message }
        for message in fresh { byId[message.id] = message }
        messages = byId.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.createdAt < $1.createdAt
        }
    }

    /// Debounced so a burst of incoming messages costs one receipts round-trip pair.
    private func scheduleReceipts() {
        receiptsTask?.cancel()
        receiptsTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await markAndFetchReceipts()
        }
    }

    private func handleTyping(_ payload: JSONObject) async {
        // supabase-swift delivers the outer broadcast envelope; the user data is nested under "payload"
        let inner = payload["payload"]?.objectValue ?? payload
        guard
            let userId = inner["userId"]?.stringValue,
            let isTyping = inner["isTyping"]?.boolValue,
            userId.lowercased() != currentUserId.uuidString.lowercased()
        else { return }

        typingTimers[userId]?.cancel()
        typingTimers[userId] = nil

        if isTyping {
            if !typingUserIds.contains(userId) { typingUserIds.append(userId) }
            typingTimers[userId] = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.typingUserIds.removeAll { $0 == userId } }
            }
        } else {
            typingUserIds.removeAll { $0 == userId }
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
        // Only over a joined channel: on an unjoined one the SDK silently re-sends it
        // through the REST broadcast endpoint, which is what the "falling back to REST
        // API" log was. A dropped typing blip is harmless.
        guard let channel = typingChannel, channel.status == .subscribed else { return }
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
        let decryptStart = ContinuousClock.now
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
        // created_at is the server's clock, so the first figure includes any skew.
        print("[Perf] received \(id): rendered \(Int(Date().timeIntervalSince(createdAt) * 1000))ms after created_at, decrypt \(Self.ms(since: decryptStart))ms")
        // Off the receive path: this is two round-trips, and awaiting it here held
        // up the next queued insert in the same `for await` loop.
        scheduleReceipts()
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
    /// The `message_id` of a realtime row, when it refers to a message currently
    /// loaded here. O(1) against the index the layout already maintains.
    private func loadedMessageId(_ record: [String: AnyJSON]) -> UUID? {
        guard
            let raw = record["message_id"]?.stringValue,
            let id = UUID(uuidString: raw),
            layout.messagesById[id] != nil
        else { return nil }
        return id
    }

    private func reloadReactions(for messageId: UUID) async {
        guard let rows = try? await repository.fetchReactions(messageIds: [messageId]) else { return }
        reactionsMap[messageId] = buildReactionGroups(from: rows)[messageId]
    }

    /// `readByOtherSet` holds own messages someone else has read, so only a
    /// receipt from another user on one of our loaded messages changes it.
    private func applyReadReceipt(_ record: [String: AnyJSON]) {
        guard
            let id = loadedMessageId(record),
            let reader = record["user_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            reader != currentUserId,
            layout.messagesById[id]?.senderId == currentUserId
        else { return }
        readByOtherSet.insert(id)
    }

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

    /// Elapsed milliseconds, for the `[Perf]` log lines.
    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now).components
        return Int(d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000)
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
    static func parseRealtimeDate(_ str: String) -> Date? {
        _dateParserFull.date(from: str) ?? _dateParserPlain.date(from: str)
    }

    // MARK: - Encryption helpers (v2 — branches on enc_v first, then iv)

    /// Decrypts a page in two phases: one batched envelope query, then a pure
    /// in-memory unwrap per message.
    ///
    /// This used to be a strictly sequential loop where every message awaited
    /// its own `message_envelopes` round-trip and re-read the Keychain, so a
    /// 50-message page cost 50 serial network calls and ~100 Keychain reads
    /// before anything rendered.
    private func decryptAll(_ raw: [DbMessage]) async -> [DecryptedMessage] {
        let ordered = raw.reversed().map { $0 }

        // Registration is single-flight, and the candidate fingerprints it
        // produces are the same for every message — so both belong outside the
        // loop. Still awaited BEFORE any failure is declared, so a device that
        // hasn't finished registering isn't wrongly reported as undecryptable.
        let v2 = ordered.filter { $0.encV == 2 && $0.iv != nil }
        var envelopes: [UUID: MessageEnvelope] = [:]
        if !v2.isEmpty {
            try? await EncryptionRegistrar.shared.ensureEncryptionKeys(userId: currentUserId)
            let candidates = KeyStore.candidateFingerprints(forUser: currentUserId)
            envelopes = (try? await repository.fetchEnvelopes(
                messageIds: v2.map(\.id),
                candidateFps: candidates
            )) ?? [:]
        }

        // Key lookup touches KeyStore's cache, so it stays here; the ECDH + AES
        // work for the whole page then runs off the main actor, where it used to
        // compete with laying out the rows it was producing.
        var keys: [String: P256.KeyAgreement.PrivateKey] = [:]
        for fp in Set(envelopes.values.map(\.recipientFp)) {
            keys[fp] = KeyStore.privateKey(forFingerprint: fp, userId: currentUserId)
        }
        let jobs: [(id: UUID, envelope: MessageEnvelope, content: String, iv: String, key: P256.KeyAgreement.PrivateKey)] =
            v2.compactMap { msg in
                guard let iv = msg.iv, let envelope = envelopes[msg.id], let key = keys[envelope.recipientFp]
                else { return nil }
                return (msg.id, envelope, msg.content, iv, key)
            }
        let plaintexts: [UUID: String] = jobs.isEmpty ? [:] : await Task.detached(priority: .userInitiated) {
            var out: [UUID: String] = [:]
            for job in jobs {
                if let text = EnvelopeEncryption.unwrap(
                    envelope: job.envelope, content: job.content, iv: job.iv, privateKey: job.key
                ) { out[job.id] = text }
            }
            return out
        }.value

        var result: [DecryptedMessage] = []
        result.reserveCapacity(ordered.count)
        for msg in ordered {
            let (content, failed) = decryptDbMessage(msg, plaintext: plaintexts[msg.id])
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

    // Batch form of `decryptDbMessage`, against a plaintext already unwrapped in
    // `decryptAll`. Same branch order and failure semantics: no plaintext for an
    // enc_v=2 message (no envelope, no key, bad wrap) is a permanent, honest
    // failure, never a fall-through.
    private func decryptDbMessage(
        _ msg: DbMessage,
        plaintext: String?
    ) -> (content: String, failed: Bool) {
        if msg.encV == 2 {
            guard msg.iv != nil, let plaintext else { return ("", true) }
            return (plaintext, false)
        } else if msg.encV == nil && msg.iv == nil {
            return (EncryptionService.decryptLegacy(msg.content) ?? msg.content, false)
        } else {
            return ("", true)
        }
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
