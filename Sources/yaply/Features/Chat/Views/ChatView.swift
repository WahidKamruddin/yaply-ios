import SwiftUI

struct ChatView: View {
    let conversationId: UUID
    let currentUserId: UUID
    let conversationName: String
    let otherMember: MemberSummary?

    @State private var vm: ChatViewModel
    @State private var messageText = ""
    @State private var showMedia = false
    @State private var isAtBottom = true
    @Environment(AppRouter.self) private var router

    private let convRepository = ConversationRepository()

    init(conversationId: UUID, currentUserId: UUID, conversationName: String, otherMember: MemberSummary?) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        self.conversationName = conversationName
        self.otherMember = otherMember
        _vm = State(initialValue: ChatViewModel(conversationId: conversationId, currentUserId: currentUserId))
    }

    private var isOnline: Bool { otherMember?.profile.isOnline ?? false }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Message list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Load older messages trigger
                            if vm.hasMore {
                                ProgressView()
                                    .padding()
                                    .onAppear { Task { await vm.loadOlderMessages() } }
                            }

                            // Group messages by date
                            let grouped = groupByDate(vm.messages)
                            ForEach(grouped, id: \.date) { group in
                                DateSeparatorView(date: group.date)
                                ForEach(group.messages) { msg in
                                    MessageBubbleView(
                                        message: msg,
                                        isOwn: msg.senderId == currentUserId,
                                        onReply: { vm.replyToMessage = $0 },
                                        onDelete: { id in Task { await vm.deleteMessage(id: id) } }
                                    )
                                    .id(msg.id)
                                }
                            }

                            // Scroll anchor
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .task {
                        await vm.onAppear()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                // Input
                MessageInputView(
                    text: $messageText,
                    replyTo: vm.replyToMessage,
                    onSend: {
                        let text = messageText
                        messageText = ""
                        Task { await vm.sendMessage(text: text) }
                    },
                    onAttachment: { showMedia = true },
                    onCancelReply: { vm.replyToMessage = nil },
                    disabled: vm.isSending
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
                    if let other = otherMember {
                        Text(isOnline ? "Online" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(isOnline ? Color.green : Color.yaplySecondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                AvatarView(
                    url: otherMember?.profile.avatarUrl,
                    name: conversationName,
                    size: 32
                )
            }
        }
        .onDisappear { vm.onDisappear() }
        .task {
            try? await convRepository.markRead(conversationId: conversationId, userId: currentUserId)
        }
        .sheet(isPresented: $showMedia) {
            MediaPickerView()
        }
    }

    // Group messages by calendar day for DateSeparatorView
    private func groupByDate(_ messages: [DecryptedMessage]) -> [(date: Date, messages: [DecryptedMessage])] {
        var groups: [(date: Date, messages: [DecryptedMessage])] = []
        var lastDate: Date?
        var current: [DecryptedMessage] = []

        for msg in messages {
            let day = Calendar.current.startOfDay(for: msg.serverTimestamp)
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
