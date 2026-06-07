import SwiftUI

struct ReminderListView: View {
    let conversationId: UUID
    let currentUserId: UUID

    @State private var reminders: [YaplyReminder] = []
    @State private var isLoading = false
    @State private var reminderToDismiss: YaplyReminder?

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
                        Image(systemName: "bell")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.yaplySecondary)
                        Text("No reminders")
                            .foregroundStyle(Color.yaplySecondary)
                        Text("Use /remind [time] [message]")
                            .font(.caption)
                            .foregroundStyle(Color.yaplySecondary.opacity(0.7))
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(reminders) { reminder in
                            ReminderRowView(reminder: reminder)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        reminderToDismiss = reminder
                                    } label: {
                                        Label("Dismiss", systemImage: "bell.slash")
                                    }
                                    .tint(Color.orange)
                                }
                                .listRowBackground(Color.white)
                        }
                    }
                    .listStyle(.plain)
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
        .alert("Dismiss Reminder", isPresented: Binding(
            get: { reminderToDismiss != nil },
            set: { if !$0 { reminderToDismiss = nil } }
        )) {
            Button("Dismiss", role: .destructive) {
                guard let r = reminderToDismiss else { return }
                reminderToDismiss = nil
                Task {
                    try? await repo.dismissReminder(id: r.id)
                    reminders.removeAll { $0.id == r.id }
                }
            }
            Button("Cancel", role: .cancel) { reminderToDismiss = nil }
        } message: {
            Text("Dismiss \"\(reminderToDismiss?.message ?? "")\"?")
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
                Text(reminder.message)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.yaplyPrimary)
                Text(reminder.remindAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(isPast ? Color.orange : Color.yaplySecondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
