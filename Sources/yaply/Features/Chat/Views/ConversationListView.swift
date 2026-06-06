import SwiftUI

struct ConversationListView: View {
    let currentUserId: UUID
    @State private var vm = ConversationListViewModel()
    @State private var showNewConversation = false
    @State private var searchText = ""
    @Environment(AppRouter.self) private var router

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
            }
        }
        .navigationBarHidden(true)
        .task { await vm.load(userId: currentUserId) }
        .onDisappear { vm.stopRealtime() }
        .sheet(isPresented: $showNewConversation) {
            NewConversationView(currentUserId: currentUserId) { convId in
                showNewConversation = false
                router.push(.conversation(id: convId))
            }
        }
        .refreshable { await vm.refresh(userId: currentUserId) }
    }
}
