import SwiftUI
import Auth

struct ConversationListView: View {
    let currentUserId: UUID
    @State private var vm = ConversationListViewModel()
    @State private var profileVm = ProfileViewModel()
    @State private var showNewConversation = false
    @State private var showProfile = false
    @State private var searchText = ""
    private let convRepository = ConversationRepository()
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var authService
    @Environment(NotificationManager.self) private var notifications

    private var filtered: [ConversationListItem] {
        guard !searchText.isEmpty else { return vm.conversations }
        return vm.conversations.filter { item in
            item.displayName(currentUserId: currentUserId).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Messages")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.yaplyPrimary)
                    Spacer()
                    Button(action: { showNewConversation = true }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.yaplyAccent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.yaplySecondary)
                        .font(.system(size: 14))
                    TextField("Search conversations...", text: $searchText)
                        .font(.system(size: 14))
                }
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider().foregroundStyle(Color.yaplyBorder)

                // Conversation list / empty state
                if vm.isLoading {
                    Spacer()
                    ProgressView()
                        .tint(Color.yaplyAccent)
                    Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.yaplySecondary)
                        Text(searchText.isEmpty ? "No conversations yet" : "No results")
                            .font(.subheadline)
                            .foregroundStyle(Color.yaplySecondary)
                        if searchText.isEmpty {
                            Button("Start a conversation") { showNewConversation = true }
                                .font(.subheadline)
                                .foregroundStyle(Color.yaplyAccent)
                        }
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { item in
                                SwipeToDeleteConversationRow(
                                    onDelete: {
                                        guard let uid = vm.currentUserId else { return }
                                        Task { await vm.deleteConversation(id: item.id, userId: uid) }
                                    }
                                ) {
                                    Button(action: { router.push(.conversation(id: item.id)) }) {
                                        ConversationRowView(item: item, currentUserId: currentUserId)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { muteMenu(for: item) }
                                }
                                Divider()
                                    .padding(.leading, 76)
                                    .foregroundStyle(Color.yaplyBorder)
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 0)
                        .padding(.top, 8)
                    }
                }

                bottomBar
            }
        }
        .navigationBarHidden(true)
        .task {
            vm.currentUserId = currentUserId
            vm.onBackgroundMessage = { convId, convName, senderName in
                notifications.show(conversationId: convId, conversationName: convName, senderName: senderName)
            }
            await vm.load(userId: currentUserId)
            await profileVm.load(userId: currentUserId)
        }
        .onChange(of: router.activeConversationId) { _, newId in
            vm.activeConversationId = newId
        }
        .onDisappear { vm.stopRealtime() }
        .sheet(isPresented: $showNewConversation) {
            NewConversationView(currentUserId: currentUserId) { convId in
                showNewConversation = false
                router.push(.conversation(id: convId))
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView(
                userId: currentUserId,
                userEmail: authService.currentUser?.email ?? ""
            )
        }
        .refreshable { await vm.refresh(userId: currentUserId) }
    }

    // MARK: - Delete helpers

    // MARK: - Mute helpers

    @ViewBuilder
    private func muteMenu(for item: ConversationListItem) -> some View {
        if item.isMuted {
            Button {
                Task { await muteItem(item.id, until: nil) }
            } label: {
                Label("Unmute", systemImage: "bell")
            }
        } else {
            Button {
                Task { await muteItem(item.id, until: Date().addingTimeInterval(3_600)) }
            } label: { Label("Mute 1 hour", systemImage: "bell.slash") }
            Button {
                Task { await muteItem(item.id, until: Date().addingTimeInterval(3_600 * 8)) }
            } label: { Label("Mute 8 hours", systemImage: "bell.slash") }
            Button {
                Task { await muteItem(item.id, until: Date().addingTimeInterval(3_600 * 24 * 7)) }
            } label: { Label("Mute 1 week", systemImage: "bell.slash") }
            Button {
                Task { await muteItem(item.id, until: Date(timeIntervalSince1970: 8_640_000_000)) }
            } label: { Label("Mute forever", systemImage: "bell.slash.fill") }
        }
    }

    private func muteItem(_ conversationId: UUID, until: Date?) async {
        try? await convRepository.muteConversation(conversationId: conversationId, userId: currentUserId, until: until)
        await vm.refresh(userId: currentUserId)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().foregroundStyle(Color.yaplyBorder)

            HStack(spacing: 10) {
                Button { showProfile = true } label: {
                    HStack(spacing: 10) {
                        AvatarView(
                            url: profileVm.profile?.avatarUrl,
                            name: profileVm.profile?.name ?? "You",
                            size: 34
                        )
                        Text(profileVm.profile?.name ?? "You")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.yaplyPrimary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button { showProfile = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.yaplyBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Button {
                    Task { try? await authService.signOut() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.yaplySecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.yaplyBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white)
        }
    }
}

// MARK: - Swipe-to-delete row wrapper

private struct SwipeToDeleteConversationRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    private let revealWidth: CGFloat = 68
    private let threshold: CGFloat = 36

    @State private var offset: CGFloat = 0
    @State private var showConfirm = false

    var body: some View {
        ZStack(alignment: .trailing) {
            // Red trash area revealed by swipe
            Button {
                showConfirm = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
            }
            .background(Color.red)
            .opacity(offset < 0 ? 1 : 0)

            content()
                .background(Color.white)
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) > abs(dy) else { return }
                            if dx < 0 {
                                offset = max(-revealWidth, dx)
                            } else if offset < 0 {
                                offset = min(0, offset + dx)
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                offset = offset < -threshold ? -revealWidth : 0
                            }
                        }
                )
        }
        .clipped()
        .alert("Delete Conversation", isPresented: $showConfirm) {
            Button("Delete", role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { offset = 0 }
                onDelete()
            }
            Button("Cancel", role: .cancel) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { offset = 0 }
            }
        } message: {
            Text("This will remove the conversation from your list.")
        }
    }
}
