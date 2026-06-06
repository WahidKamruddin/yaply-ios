import SwiftUI

struct ChatView: View {
    let conversationId: UUID
    let currentUserId: UUID
    let currentUsername: String
    let conversationName: String
    let otherMember: MemberSummary?

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
    @Environment(AppRouter.self) private var router

    private let convRepository = ConversationRepository()

    init(conversationId: UUID, currentUserId: UUID, currentUsername: String, conversationName: String, otherMember: MemberSummary?) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        self.currentUsername = currentUsername
        self.conversationName = conversationName
        self.otherMember = otherMember
        _vm = State(initialValue: ChatViewModel(conversationId: conversationId, currentUserId: currentUserId))
    }

    private var isOnline: Bool { otherMember?.profile.isOnline ?? false }

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
                    .background(Color.white)
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
                                        swipeOffset: swipeOffset
                                    )
                                    .id(msg.id)
                                    .background(highlightedId == msg.id ? Color.yaplyAccent.opacity(0.12) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .animation(.easeInOut(duration: 0.3), value: highlightedId)
                                }
                            }

                            if !vm.typingUsernames.isEmpty {
                                HStack(spacing: 6) {
                                    TypingDotsView()
                                    Text(typingLabel)
                                        .font(.caption)
                                        .foregroundStyle(Color.yaplySecondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .id("typing")
                            }

                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.vertical, 8)
                    }
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
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: vm.typingUsernames.isEmpty) { _, isEmpty in
                        if !isEmpty { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
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
                        await vm.onAppear()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                MessageInputView(
                    text: $messageText,
                    replyTo: vm.replyToMessage,
                    onSend: {
                        let text = messageText
                        messageText = ""
                        vm.notifyStopTyping()
                        Task { await vm.sendMessage(text: text) }
                    },
                    onAttachment: { showMedia = true },
                    onCancelReply: { vm.replyToMessage = nil },
                    disabled: vm.isSending,
                    onTyping: { vm.notifyTyping() },
                    onStopTyping: { vm.notifyStopTyping() }
                )
            }
        }
        .navigationTitle(conversationName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(conversationName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                    if otherMember != nil {
                        Text(isOnline ? "Online" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(isOnline ? Color.green : Color.yaplySecondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { searchIsActive.toggle() }
                        if !searchIsActive { searchQuery = "" }
                    } label: {
                        Image(systemName: searchIsActive ? "xmark" : "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.yaplyAccent)
                    }
                    if vm.isGroupConversation {
                        Button { showGroupInfo = true } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.yaplyAccent)
                        }
                    } else {
                        AvatarView(
                            url: otherMember?.profile.avatarUrl,
                            name: conversationName,
                            size: 32
                        )
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
                onRefresh: { await vm.loadConversationInfo() }
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
        .alert("Error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK", role: .cancel) { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    private var typingLabel: String {
        let names = vm.typingUsernames
        if names.count == 1 { return "\(names[0]) is typing…" }
        return "\(names.dropLast().joined(separator: ", ")) and \(names.last!) are typing…"
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
}

private struct TypingDotsView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.yaplySecondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase == i ? 1.3 : 0.8)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15), value: phase)
            }
        }
        .onAppear {
            withAnimation { phase = (phase + 1) % 3 }
        }
    }
}
