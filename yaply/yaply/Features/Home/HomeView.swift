import SwiftUI

// The Home tab — mirrors web's Dashboard.tsx: a greeting, quick-create
// actions, and cross-conversation Reminders / Events / Friends feeds.
struct HomeView: View {
    let currentUserId: UUID
    let conversations: [ConversationListItem]
    let isLoadingConversations: Bool
    let onOpenConversation: (UUID) -> Void

    @State private var vm = HomeViewModel()
    @State private var creating: DashboardCreateType?

    private var friends: [(userId: UUID, profile: Profile)] {
        var seen: [UUID: Profile] = [:]
        var order: [UUID] = []
        for conv in conversations where !conv.isGroup {
            guard let other = conv.otherMember(currentUserId: currentUserId), seen[other.userId] == nil else { continue }
            seen[other.userId] = other.profile
            order.append(other.userId)
        }
        return order.compactMap { id in seen[id].map { (id, $0) } }
    }

    private func conversationLabel(_ conversationId: UUID) -> String {
        conversations.first(where: { $0.id == conversationId })?.displayName(currentUserId: currentUserId) ?? "Unknown chat"
    }

    private func directConversation(for userId: UUID) -> UUID? {
        conversations.first(where: { !$0.isGroup && $0.otherMember(currentUserId: currentUserId)?.userId == userId })?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HomeViewModel.greeting(name: vm.displayName))
                        .font(.display(22, weight: .bold))
                        .foregroundStyle(Color.yaplyPrimary)
                    Text("Here's what's coming up across your chats")
                        .font(.subheadline)
                        .foregroundStyle(Color.yaplySecondary)
                }

                HStack(spacing: 10) {
                    Button {
                        creating = .reminder
                    } label: {
                        Label("Reminder", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.yaplyAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    Button {
                        creating = .event
                    } label: {
                        Label("Event", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.yaplyPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.yaplyTint)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yaplyBorder))
                    }
                    .buttonStyle(.plain)
                }

                remindersCard
                eventsCard
                friendsCard

                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 11))
                    Text("Pick a chat from Chats to jump back into a conversation")
                        .font(.caption)
                }
                .foregroundStyle(Color.yaplySecondary)
            }
            .padding(20)
        }
        .task { await vm.load(userId: currentUserId) }
        .refreshable { await vm.load(userId: currentUserId) }
        .sheet(item: $creating) { type in
            DashboardCreateView(
                type: type,
                conversations: conversations,
                currentUserId: currentUserId,
                onCreated: { Task { await vm.load(userId: currentUserId) } }
            )
        }
    }

    // MARK: - Reminders

    private var remindersCard: some View {
        cardShell(icon: "bell.fill", title: "Reminders") {
            if vm.isLoading {
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        DashboardRowSkeleton(delay: Double(i) * 0.06)
                    }
                }
            } else if vm.reminders.isEmpty {
                emptyRow("No reminders yet")
            } else {
                VStack(spacing: 2) {
                    ForEach(vm.reminders) { reminder in
                        Button {
                            if let cid = reminder.conversationId { onOpenConversation(cid) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.yaplySecondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reminder.message)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.yaplyPrimary)
                                        .lineLimit(1)
                                    Text("\(HomeViewModel.relativeTime(reminder.remindAt)) · \(reminder.conversationId.map(conversationLabel) ?? "Unknown chat")")
                                        .font(.caption)
                                        .foregroundStyle(Color.yaplySecondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Events

    private var eventsCard: some View {
        cardShell(icon: "calendar", title: "Events") {
            if vm.isLoading {
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        DashboardRowSkeleton(delay: Double(i) * 0.06)
                    }
                }
            } else if vm.upcomingEvents.isEmpty {
                emptyRow("No upcoming events")
            } else {
                VStack(spacing: 2) {
                    ForEach(vm.upcomingEvents) { event in
                        Button {
                            onOpenConversation(event.conversationId)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: event.isPlanning ? "map" : "calendar")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.yaplySecondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.yaplyPrimary)
                                        .lineLimit(1)
                                    Text("\(event.isPlanning ? "Planning" : event.startsAt.map(HomeViewModel.relativeTime) ?? "") · \(conversationLabel(event.conversationId))")
                                        .font(.caption)
                                        .foregroundStyle(Color.yaplySecondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Friends

    private var friendsCard: some View {
        cardShell(icon: "person.2.fill", title: "Friends") {
            if isLoadingConversations {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(0..<6, id: \.self) { i in
                        DashboardFriendSkeleton(delay: Double(i) * 0.06)
                    }
                }
            } else if friends.isEmpty {
                emptyRow("Start a direct message to see friends here")
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(friends, id: \.userId) { friend in
                        Button {
                            if let cid = directConversation(for: friend.userId) { onOpenConversation(cid) }
                        } label: {
                            HStack(spacing: 8) {
                                AvatarView(url: friend.profile.avatarUrl, name: friend.profile.name, size: 28)
                                Text(friend.profile.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.yaplyPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Shared card shell

    private func cardShell<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.yaplyTint)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.yaplyAccent))
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.yaplyPrimary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yaplyCard)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.yaplyBorder))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.yaplySecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

extension DashboardCreateType: Identifiable {
    var id: Self { self }
}
