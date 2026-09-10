import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let conversationId: UUID
    let currentUserId: UUID
    let currentUsername: String
    let conversationName: String

    @State private var vm: ChatViewModel
    @State private var messageText = ""
    @State private var showMedia = false
    @State private var threadRoot: DecryptedMessage?
    @State private var scrollToId: UUID?
    @State private var highlightedId: UUID?
    @State private var searchIsActive = false
    @State private var searchQuery = ""
    @State private var showGroupInfo = false
    @State private var swipeOffset: CGFloat = 0
    @State private var distFromBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 1
    @State private var newMsgCount = 0
    @State private var commandFeedback: String?
    @State private var showProfile = false

    private var isNearBottom: Bool { distFromBottom <= viewportHeight }
    private var showScrollButton: Bool { distFromBottom > viewportHeight }
    @State private var feedbackDismissTask: Task<Void, Never>?
    @State private var showHelp = false
    @State private var isDropTargeted = false
    @Environment(AppRouter.self) private var router

    private let convRepository = ConversationRepository()

    init(conversationId: UUID, currentUserId: UUID, currentUsername: String, conversationName: String) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        self.currentUsername = currentUsername
        self.conversationName = conversationName
        _vm = State(initialValue: ChatViewModel(conversationId: conversationId, currentUserId: currentUserId))
    }

    private var currentOtherMember: MemberSummary? {
        vm.conversationMembers.first(where: { $0.userId != currentUserId })
    }
    private var isOnline: Bool { currentOtherMember?.profile.isOnline ?? false }
    private var displayName: String {
        if vm.isGroupConversation { return vm.groupName ?? conversationName }
        return currentOtherMember?.profile.name ?? conversationName
    }

    private var displayMessages: [DecryptedMessage] {
        guard !searchQuery.isEmpty else { return vm.messages }
        return vm.messages.filter { msg in
            !msg.isDeleted && msg.isText && msg.content.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var lastOwnMessageId: UUID? {
        displayMessages.last(where: { $0.senderId == currentUserId && !$0.isDeleted })?.id
    }

    private var threadCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for msg in vm.messages {
            if let tid = msg.threadId { counts[tid, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {

        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if searchIsActive {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.yaplySecondary)
                        TextField("Search messages…", text: $searchQuery)
                            .font(.system(size: 14))
                        if !searchQuery.isEmpty {
                            Button { searchQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.yaplySecondary)
                            }
                        }
                    }
                    .padding(9)
                    .background(Color.yaplyTint)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if vm.hasMore {
                                ProgressView()
                                    .padding()
                                    .onAppear { Task { await vm.loadOlderMessages() } }
                            }

                            let grouped = groupByDate(displayMessages)
                            ForEach(grouped, id: \.date) { group in
                                DateSeparatorView(date: group.date)
                                ForEach(group.messages) { msg in
                                    MessageBubbleView(
                                        message: msg,
                                        isOwn: msg.senderId == currentUserId,
                                        replyMessage: msg.replyToId.flatMap { rid in vm.messages.first { $0.id == rid } },
                                        threadCount: threadCounts[msg.id] ?? 0,
                                        isRead: msg.senderId == currentUserId && msg.id == lastOwnMessageId ? vm.readByOtherSet.contains(msg.id) : nil,
                                        reactions: vm.reactionsMap[msg.id] ?? [],
                                        onReply: { vm.replyToMessage = $0 },
                                        onDelete: { id in Task { await vm.deleteMessage(id: id) } },
                                        onReact: { msgId, emoji in vm.toggleReaction(messageId: msgId, emoji: emoji) },
                                        onOpenThread: { threadRoot = $0 },
                                        onReplyInThread: { threadRoot = $0 },
                                        onQuotationClick: { id in scrollToId = id },
                                        onOpenDetail: { openPanel($0) },
                                        swipeOffset: swipeOffset
                                    )
                                    .id(msg.id)
                                    .background(highlightedId == msg.id ? Color.yaplyAccent.opacity(0.12) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .animation(.easeInOut(duration: 0.3), value: highlightedId)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                }
                            }

                            if !vm.typingUsernames.isEmpty {
                                let typingMember = vm.conversationMembers.first(where: { $0.profile.username == vm.typingUsernames.first })
                                HStack(alignment: .bottom, spacing: 8) {
                                    AvatarView(
                                        url: typingMember?.profile.avatarUrl,
                                        name: vm.typingUsernames.first ?? "?",
                                        size: 28
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("placeholder")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .hidden()
                                        TypingBubbleView()
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                                .id("typing")
                            }

                            Color.clear.frame(height: 10).id("bottom")
                        }
                        .padding(.vertical, 8)
                    }
                    .onScrollGeometryChange(for: CGPoint.self) { geo in
                        CGPoint(
                            x: geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height),
                            y: geo.containerSize.height
                        )
                    } action: { _, new in
                        distFromBottom = max(0, new.x)
                        viewportHeight = max(1, new.y)
                        if isNearBottom { newMsgCount = 0 }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showScrollButton {
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    newMsgCount = 0
                                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 36, height: 36)
                                        .background(Color.yaplyAccent)
                                        .clipShape(Circle())
                                        .shadow(color: Color.yaplyAccent.opacity(0.35), radius: 6, y: 2)
                                }
                                if newMsgCount > 0 {
                                    Text(newMsgCount > 99 ? "99+" : "\(newMsgCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 18, minHeight: 18)
                                        .background(Color.yaplyDanger)
                                        .clipShape(Capsule())
                                        .offset(x: 6, y: -6)
                                }
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 10)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: showScrollButton)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > abs(dy) else { return }
                                swipeOffset = max(-65, min(0, dx))
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    swipeOffset = 0
                                }
                            }
                    )
                    .onChange(of: vm.messages.count) { _, _ in
                        handleMessageCountChange(proxy: proxy)
                    }
                    .onChange(of: vm.typingUsernames.isEmpty) { _, isEmpty in
                        if !isEmpty && isNearBottom {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                    .onChange(of: scrollToId) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                        scrollToId = nil
                        highlightedId = id
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            highlightedId = nil
                        }
                    }
                    .task {
                        vm.currentUsername = currentUsername
                        newMsgCount = 0
                        await vm.onAppear()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                // Command feedback banner
                if let feedback = commandFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.yaplySecondary)
                        Text(feedback)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.yaplySecondary)
                        Spacer()
                        Button { commandFeedback = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.yaplySecondary.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.yaplyTint)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yaplyBorder.opacity(0.8)))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if vm.myRequestState == "pending" {
                    MessageRequestBarView(
                        conversationId: conversationId,
                        currentUserId: currentUserId,
                        otherUserId: currentOtherMember?.userId,
                        onAccepted: { vm.setMyRequestState("accepted") },
                        onDeclinedOrBlocked: { router.pop() }
                    )
                } else {
                    MessageInputView(
                        text: $messageText,
                        replyTo: vm.replyToMessage,
                        onSend: {
                            let rawText = messageText.trimmingCharacters(in: .whitespaces)
                            guard !rawText.isBlank else { return }
                            messageText = ""
                            vm.notifyStopTyping()
                            if let cmd = ParsedCommand.parse(rawText) {
                                Task { await handleCommand(cmd) }
                            } else {
                                Task { await vm.sendMessage(text: rawText) }
                            }
                        },
                        onAttachment: { showMedia = true },
                        onCancelReply: { vm.replyToMessage = nil },
                        disabled: vm.isSending,
                        onTyping: { vm.notifyTyping() },
                        onStopTyping: { vm.notifyStopTyping() },
                        onPasteImage: { image in
                            Task {
                                if image.hasAlpha {
                                    await vm.sendStickerMessage(image: image)
                                } else {
                                    let resized = image.resized(maxDimension: 1280)
                                    if let jpeg = resized.jpegData(compressionQuality: 0.82) {
                                        await vm.sendImageMessage(imageData: jpeg, mimeType: "image/jpeg")
                                    }
                                }
                            }
                        }
                    )
                }
            }
        }
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.yaplyAccent.opacity(0.12).ignoresSafeArea()
                    Text("Drop to send")
                        .font(.display(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.yaplyAccent)
                        .clipShape(Capsule())
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(
                            url: vm.isGroupConversation ? nil : currentOtherMember?.profile.avatarUrl,
                            name: displayName,
                            size: 36
                        )
                        if !vm.isGroupConversation && currentOtherMember != nil {
                            PresenceDotView(isOnline: isOnline, borderColor: .yaplySurface, size: 9)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(.display(16, weight: .semibold))
                            .foregroundStyle(Color.yaplyPrimary)
                        if !vm.isGroupConversation && currentOtherMember != nil {
                            Text(isOnline ? "Online" : "Offline")
                                .font(.caption2)
                                .foregroundStyle(isOnline ? Color.yaplyOnline : Color.yaplySecondary)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !vm.isGroupConversation && currentOtherMember != nil { showProfile = true }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { searchIsActive.toggle() }
                        if !searchIsActive { searchQuery = "" }
                    } label: {
                        Image(systemName: searchIsActive ? "xmark" : "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(searchIsActive ? .white : Color.yaplyAccent)
                            .frame(width: 30, height: 30)
                            .background(searchIsActive ? Color.yaplyAccent : Color.clear)
                            .clipShape(Circle())
                    }
                    Button {
                        openPanel("tasks")
                    } label: {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.yaplyAccent)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                    }
                    if vm.isGroupConversation {
                        Button { showGroupInfo = true } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.yaplyAccent)
                        }
                    } else {
                        Button { showProfile = true } label: {
                            AvatarView(
                                url: currentOtherMember?.profile.avatarUrl,
                                name: displayName,
                                size: 32
                            )
                        }
                    }
                }
            }
        }
        .onAppear { router.activeConversationId = conversationId }
        .onDisappear {
            router.activeConversationId = nil
            vm.onDisappear()
        }
        .task {
            try? await convRepository.markRead(conversationId: conversationId, userId: currentUserId)
        }
        .sheet(isPresented: $showMedia) {
            MediaPickerView(
                onImageSelected: { data, mime in
                    Task { await vm.sendImageMessage(imageData: data, mimeType: mime) }
                },
                onGifSelected: { gif in
                    Task { await vm.sendGifMessage(url: gif.url) }
                }
            )
        }
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoView(
                conversationId: conversationId,
                conversationName: conversationName,
                currentUserId: currentUserId,
                onRefresh: { await vm.loadConversationInfo() },
                onDeleted: { router.pop() }
            )
        }
        .sheet(item: $threadRoot) { root in
            ThreadView(
                rootMessage: root,
                conversationId: conversationId,
                currentUserId: currentUserId,
                isPresented: Binding(
                    get: { threadRoot != nil },
                    set: { if !$0 { threadRoot = nil } }
                )
            )
        }
        .yaplyAlert(
            isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } }),
            title: "Something went wrong",
            message: vm.error ?? ""
        )
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .sheet(isPresented: $showProfile) {
            if let otherId = currentOtherMember?.userId {
                ProfileView(userId: otherId, viewerId: currentUserId)
            }
        }
    }


    /// Handles images dropped onto the conversation — a sticker dragged out of the
    /// iOS Stickers drawer, or a photo from Photos/Files. A transparent image is
    /// treated as a sticker (rendered bubble-free); an opaque one as a photo.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { return }
            Task { @MainActor in
                if image.hasAlpha {
                    await vm.sendStickerMessage(image: image)
                } else {
                    let resized = image.resized(maxDimension: 1280)
                    guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return }
                    await vm.sendImageMessage(imageData: jpeg, mimeType: "image/jpeg")
                }
            }
        }
        return true
    }

    /// Pushes the conversation's productivity panel as a page (Tasks / Notes /
    /// Reminders / Events / Albums / Budgets), rather than presenting a sheet.
    private func openPanel(_ tab: String) {
        router.push(.conversationPanel(
            conversationId: conversationId,
            members: vm.conversationMembers,
            tab: tab
        ))
    }

    private func handleMessageCountChange(proxy: ScrollViewProxy) {
        guard let last = vm.messages.last else { return }
        if last.senderId == currentUserId || isNearBottom {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            newMsgCount += 1
        }
    }

    private func groupByDate(_ messages: [DecryptedMessage]) -> [(date: Date, messages: [DecryptedMessage])] {
        var groups: [(date: Date, messages: [DecryptedMessage])] = []
        var lastDate: Date?
        var current: [DecryptedMessage] = []
        for msg in messages {
            let day = Calendar.current.startOfDay(for: msg.createdAt)
            if let last = lastDate, Calendar.current.isDate(day, inSameDayAs: last) {
                current.append(msg)
            } else {
                if !current.isEmpty { groups.append((date: lastDate!, messages: current)) }
                lastDate = day
                current = [msg]
            }
        }
        if !current.isEmpty, let last = lastDate {
            groups.append((date: last, messages: current))
        }
        return groups
    }

    private func handleCommand(_ cmd: ParsedCommand) async {
        switch cmd.name {
        case "remind":
            do {
                let msg = try await RemindHandler.execute(args: cmd.args, conversationId: conversationId, userId: currentUserId)
                showCommandFeedback(msg)
                NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "reminders"])
            } catch {
                showCommandFeedback(error.localizedDescription)
            }
        case "mute":
            do {
                try await MuteHandler.execute(args: cmd.args, conversationId: conversationId, userId: currentUserId)
                let label = cmd.args.first ?? "1h"
                showCommandFeedback("🔇 Muted for \(label)")
            } catch {
                showCommandFeedback("Failed: \(error.localizedDescription)")
            }
        case "task":
            if cmd.rawArgs.isBlank { openPanel("tasks") }
            else { await createItem(type: "task", title: cmd.rawArgs) }
        case "note":
            if cmd.rawArgs.isBlank { openPanel("notes") }
            else { await createItem(type: "note", title: cmd.rawArgs) }
        case "album":
            if cmd.rawArgs.isBlank { openPanel("albums") }
            else { await createItem(type: "album", title: cmd.rawArgs) }
        case "plan":
            if cmd.rawArgs.isBlank { openPanel("events") }
            else { await createItem(type: "plan", title: cmd.rawArgs) }
        case "event":
            openPanel("events")
        case "budget":
            openPanel("budgets")
        case "thread":
            showCommandFeedback("Open a thread by long-pressing a message and tapping Reply in Thread.")
        case "help":
            showHelp = true
        default:
            showCommandFeedback("Unknown command /\(cmd.name)")
        }
    }

    private func createItem(type: String, title: String) async {
        switch type {
        case "task":
            try? await TaskRepository().createTask(conversationId: conversationId, createdBy: currentUserId, title: title)
            showCommandFeedback("✓ Task created: \(title)")
            NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "tasks"])
        case "note":
            try? await NoteRepository().createNote(conversationId: conversationId, userId: currentUserId, title: title)
            showCommandFeedback("✓ Note created: \(title)")
            NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "notes"])
        case "album":
            try? await AlbumRepository().createAlbum(conversationId: conversationId, createdBy: currentUserId, name: title)
            showCommandFeedback("✓ Album created: \(title)")
            NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "albums"])
        case "plan":
            try? await EventRepository().createEvent(conversationId: conversationId, createdBy: currentUserId, name: title, status: "planning")
            showCommandFeedback("✓ Plan created: \(title)")
            NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "events"])
        default:
            break
        }
    }

    private func showCommandFeedback(_ message: String) {
        feedbackDismissTask?.cancel()
        withAnimation { commandFeedback = message }
        feedbackDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                withAnimation { commandFeedback = nil }
            }
        }
    }
}

private struct TypingBubbleView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.yaplySecondary)
                    .frame(width: 8, height: 8)
                    .offset(y: animating ? -5 : 0)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.yaplySurface)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18
        )))
        .overlay(
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18
            ))
            .stroke(Color.yaplyBorderSoft, lineWidth: 1)
        )
        .onAppear { animating = true }
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Available Commands") {
                    ForEach(YaplyCommand.allCases, id: \.rawValue) { cmd in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("/\(cmd.rawValue)")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.yaplyAccent)
                                if let hint = cmd.argHint {
                                    let pattern = hint.components(separatedBy: "  ").first ?? hint
                                    Text(pattern)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Color.yaplySecondary.opacity(0.5))
                                }
                            }
                            Text(cmd.description)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
    }
}
