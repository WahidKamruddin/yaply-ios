import SwiftUI
import Auth

private enum BottomTab {
    case home, chats, settings
}

struct ConversationListView: View {
    let currentUserId: UUID
    @State private var vm = ConversationListViewModel()
    @State private var showNewConversation = false
    @State private var searchText = ""
    @State private var bottomTab: BottomTab = .home
    @State private var conversationToDelete: ConversationListItem?
    private let convRepository = ConversationRepository()
    @Environment(AppRouter.self) private var router
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
                    HStack(spacing: 8) {
                        YaplyLogoMark(size: 26)
                        Text("yaply")
                            .font(.display(20, weight: .medium))
                            .foregroundStyle(Color.yaplyPrimary)
                    }
                    Spacer()
                    if bottomTab == .chats {
                        Button(action: { showNewConversation = true }) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    LinearGradient(
                                        colors: [Color.yaplyAccent, Color.yaplyAccentDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(Circle())
                                .shadow(color: Color.yaplyAccent.opacity(0.35), radius: 6, y: 3)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                switch bottomTab {
                case .home:
                    HomeView(
                        currentUserId: currentUserId,
                        conversations: vm.conversations,
                        onOpenConversation: { router.push(.conversation(id: $0)) }
                    )
                case .chats:
                    messagesContent
                case .settings:
                    SettingsView()
                }

                bottomNavBar
            }
        }
        .navigationBarHidden(true)
        .task {
            vm.currentUserId = currentUserId
            vm.onBackgroundMessage = { convId, convName, senderName in
                notifications.show(conversationId: convId, conversationName: convName, senderName: senderName)
            }
            await vm.load(userId: currentUserId)
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
        .refreshable { await vm.refresh(userId: currentUserId) }
        .alert(
            "Delete Conversation",
            isPresented: Binding(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            ),
            presenting: conversationToDelete
        ) { item in
            Button("Delete", role: .destructive) {
                guard let uid = vm.currentUserId else { return }
                Task { await vm.deleteConversation(id: item.id, userId: uid) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This conversation will be permanently deleted for you. This cannot be undone.")
        }
    }

    // MARK: - Messages tab content

    private var messagesContent: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.yaplySecondary)
                    .font(.system(size: 14))
                TextField("Search conversations...", text: $searchText)
                    .font(.system(size: 14))
            }
            .padding(10)
            .background(Color.yaplyTint)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider().foregroundStyle(Color.yaplyBorder)

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
                            Button(action: { router.push(.conversation(id: item.id)) }) {
                                ConversationRowView(item: item, currentUserId: currentUserId)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { rowContextMenu(for: item) }
                            Divider()
                                .padding(.leading, 76)
                                .foregroundStyle(Color.yaplyBorder)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: - Row context menu (mute + delete)

    @ViewBuilder
    private func rowContextMenu(for item: ConversationListItem) -> some View {
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
        Divider()
        Button(role: .destructive) {
            conversationToDelete = item
        } label: {
            Label("Delete conversation", systemImage: "trash")
        }
    }

    private func muteItem(_ conversationId: UUID, until: Date?) async {
        try? await convRepository.muteConversation(conversationId: conversationId, userId: currentUserId, until: until)
        await vm.refresh(userId: currentUserId)
    }

    // MARK: - Bottom nav bar (Messages / Requests / Menu)

    private var bottomNavBar: some View {
        VStack(spacing: 0) {
            Divider().foregroundStyle(Color.yaplyBorder)

            HStack(spacing: 0) {
                bottomNavButton(icon: "house.fill", label: "Home", tab: .home)
                bottomNavButton(icon: "message.fill", label: "Chats", tab: .chats)
                bottomNavButton(icon: "gearshape.fill", label: "Settings", tab: .settings)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color.yaplySurface)
        }
    }

    private func bottomNavButton(icon: String, label: String, tab: BottomTab) -> some View {
        Button { bottomTab = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(label)
                    .font(.system(size: 10, weight: bottomTab == tab ? .semibold : .medium))
            }
            .foregroundStyle(bottomTab == tab ? Color.yaplyAccent : Color.yaplySecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
