import SwiftUI

struct ConversationDetailView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var members: [MemberSummary] = []
    var initialTab: String = "reminders"

    private var isCurrentUserAdmin: Bool {
        members.first { $0.userId == currentUserId }?.isAdmin ?? false
    }

    @State private var selectedTab: String = "reminders"
    @Environment(\.dismiss) private var dismiss

    private let primaryTabs: [(id: String, label: String, icon: String)] = [
        ("reminders", "Reminders", "bell"),
        ("events",    "Events",    "calendar"),
        ("albums",    "Albums",    "photo.stack"),
    ]

    private let secondaryTabs: [(id: String, label: String, icon: String)] = [
        ("tasks",   "Tasks",   "checkmark.square"),
        ("notes",   "Notes",   "note.text"),
        ("budgets", "Budgets", "dollarsign.circle"),
    ]

    private var isSecondaryActive: Bool {
        secondaryTabs.contains { $0.id == selectedTab }
    }

    private var activeSecondaryLabel: String? {
        secondaryTabs.first { $0.id == selectedTab }?.label
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                contentView
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .onAppear { selectedTab = initialTab }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(primaryTabs, id: \.id) { tab in
                primaryTabButton(tab)
            }
            moreMenu
        }
        .background(Color.yaplySurface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func primaryTabButton(_ tab: (id: String, label: String, icon: String)) -> some View {
        Button(action: { selectedTab = tab.id }) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                Text(tab.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .foregroundStyle(selectedTab == tab.id ? Color.yaplyAccent : Color.yaplySecondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selectedTab == tab.id ? Color.yaplyAccent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private var moreMenu: some View {
        Menu {
            ForEach(secondaryTabs, id: \.id) { tab in
                Button(action: { selectedTab = tab.id }) {
                    Label(tab.label, systemImage: tab.icon)
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                Text(isSecondaryActive ? (activeSecondaryLabel ?? "More") : "More")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .foregroundStyle(isSecondaryActive ? Color.yaplyAccent : Color.yaplySecondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSecondaryActive ? Color.yaplyAccent : Color.clear)
                    .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case "tasks":
            TaskListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        case "notes":
            NoteListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        case "reminders":
            ReminderListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        case "events":
            EventListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        case "albums":
            AlbumListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        case "budgets":
            BudgetListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        default:
            ReminderListView(conversationId: conversationId, currentUserId: currentUserId, isCurrentUserAdmin: isCurrentUserAdmin)
        }
    }
}
