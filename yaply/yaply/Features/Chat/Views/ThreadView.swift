import SwiftUI

struct ThreadView: View {
    @State private var vm: ThreadViewModel
    let currentUserId: UUID
    @Binding var isPresented: Bool
    @State private var messageText = ""

    init(rootMessage: DecryptedMessage, conversationId: UUID, currentUserId: UUID, isPresented: Binding<Bool>) {
        _vm = State(initialValue: ThreadViewModel(
            rootMessage: rootMessage,
            conversationId: conversationId,
            currentUserId: currentUserId
        ))
        self.currentUserId = currentUserId
        _isPresented = isPresented
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.yaplyBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                // Root message shown at top
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Original message")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.yaplySecondary)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)

                                    MessageBubbleView(
                                        message: vm.rootMessage,
                                        isOwn: vm.rootMessage.senderId == currentUserId,
                                        reactions: [],
                                        onReply: { _ in },
                                        onDelete: { _ in }
                                    )
                                }
                                .background(Color.white)
                                .overlay(Divider(), alignment: .bottom)
                                .padding(.bottom, 8)

                                // Thread reply count
                                HStack {
                                    Text(vm.replies.isEmpty
                                         ? "No replies yet"
                                         : "\(vm.replies.count) \(vm.replies.count == 1 ? "reply" : "replies")")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.yaplySecondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)

                                if vm.isLoading {
                                    ProgressView().padding()
                                } else {
                                    ForEach(vm.replies) { msg in
                                        MessageBubbleView(
                                            message: msg,
                                            isOwn: msg.senderId == currentUserId,
                                            replyMessage: replyMessageFor(msg),
                                            reactions: [],
                                            onReply: { _ in },
                                            onDelete: { _ in }
                                        )
                                        .id(msg.id)
                                    }
                                }

                                Color.clear.frame(height: 1).id("threadBottom")
                            }
                            .padding(.bottom, 8)
                        }
                        .onChange(of: vm.replies.count) { _, _ in
                            withAnimation { proxy.scrollTo("threadBottom", anchor: .bottom) }
                        }
                        .task {
                            await vm.onAppear()
                            proxy.scrollTo("threadBottom", anchor: .bottom)
                        }
                    }

                    MessageInputView(
                        text: $messageText,
                        replyTo: nil,
                        onSend: {
                            let text = messageText
                            messageText = ""
                            Task { await vm.sendReply(text: text) }
                        },
                        onAttachment: { },
                        onCancelReply: { },
                        disabled: vm.isSending
                    )
                }
            }
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { isPresented = false }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .onDisappear { vm.onDisappear() }
    }

    private func replyMessageFor(_ msg: DecryptedMessage) -> DecryptedMessage? {
        guard let rid = msg.replyToId else { return nil }
        if rid == vm.rootMessage.id { return nil }
        return vm.replies.first { $0.id == rid }
    }
}
