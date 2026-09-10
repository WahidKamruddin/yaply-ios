import SwiftUI

struct ReminderListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @State private var reminders: [YaplyReminder] = []
    @State private var isLoading = false
    @State private var reminderToDismiss: YaplyReminder?
    @State private var reminderToEditTime: YaplyReminder?
    @State private var editRemindAt = Date()

    private let repo = ReminderRepository()

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if reminders.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        EmptyStateView(icon: "bell", title: "No reminders")
                        Text("Use /remind [time] [message]")
                            .font(.caption)
                            .foregroundStyle(Color.yaplySecondary.opacity(0.7))
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(reminders) { reminder in
                            ReminderRowView(reminder: reminder, isCurrentUserAdmin: isCurrentUserAdmin) {
                                editRemindAt = reminder.remindAt
                                reminderToEditTime = reminder
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                let canDismiss = reminder.userId == currentUserId || isCurrentUserAdmin
                                let canInteract = !reminder.locked || isCurrentUserAdmin
                                Button(role: canDismiss && canInteract ? .destructive : .none) {
                                    if canDismiss && canInteract { reminderToDismiss = reminder }
                                } label: {
                                    Label("Dismiss", systemImage: "bell.slash")
                                }
                                .tint(canDismiss && canInteract ? Color.orange : Color(UIColor.systemGray4))
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if isCurrentUserAdmin {
                                    Button {
                                        Task {
                                            try? await repo.setLocked(id: reminder.id, locked: !reminder.locked)
                                            await load()
                                        }
                                    } label: {
                                        Label(reminder.locked ? "Unlock" : "Lock",
                                              systemImage: reminder.locked ? "lock.open" : "lock")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .yaplyCardStyle()
                            .yaplyCardRowContainer()
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .yaplyItemCreated)) { notif in
            guard (notif.userInfo?["type"] as? String) == "reminders" else { return }
            Task { await load() }
        }
        .yaplyPopup(item: $reminderToEditTime) { reminder in
            YaplySheetScaffold(
                title: "Edit reminder time",
                primaryLabel: "Save",
                primaryAction: {
                    reminderToEditTime = nil
                    Task {
                        try? await repo.updateRemindAt(reminderId: reminder.id, remindAt: editRemindAt)
                        await load()
                    }
                }
            ) {
                YaplyLabeledField(label: "Remind at") {
                    DatePicker("", selection: $editRemindAt, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .yaplyConfirm(
            isPresented: Binding(get: { reminderToDismiss != nil }, set: { if !$0 { reminderToDismiss = nil } }),
            title: "Dismiss reminder",
            message: "Dismiss \"\(reminderToDismiss?.message ?? "")\"?",
            icon: "bell.slash.fill",
            confirmLabel: "Dismiss"
        ) {
            guard let r = reminderToDismiss else { return }
            reminderToDismiss = nil
            Task {
                try? await repo.dismissReminder(id: r.id)
                reminders.removeAll { $0.id == r.id }
            }
        }
    }

    private func load() async {
        isLoading = true
        reminders = (try? await repo.fetchReminders(conversationId: conversationId)) ?? []
        isLoading = false
    }
}

private struct ReminderRowView: View {
    let reminder: YaplyReminder
    let isCurrentUserAdmin: Bool
    let onEditTime: () -> Void

    private var isPast: Bool { reminder.remindAt <= Date() }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isPast ? Color.orange.opacity(0.15) : Color.yaplyBackground)
                    .frame(width: 36, height: 36)
                Image(systemName: isPast ? "bell.badge" : "bell")
                    .font(.system(size: 14))
                    .foregroundStyle(isPast ? Color.orange : Color.yaplyAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if reminder.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    Text(reminder.message)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.yaplyPrimary)
                }
                HStack(spacing: 4) {
                    Text(reminder.remindAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .foregroundStyle(isPast ? Color.orange : Color.yaplySecondary)
                    if isCurrentUserAdmin {
                        Button(action: onEditTime) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("·")
                        .foregroundStyle(Color.yaplySecondary.opacity(0.4))
                    Text("set by \(reminder.creator?.name ?? "Unknown")")
                        .foregroundStyle(Color.yaplySecondary)
                }
                .font(.caption)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
