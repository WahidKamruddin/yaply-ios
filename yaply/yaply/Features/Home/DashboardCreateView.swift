import SwiftUI

enum DashboardCreateType {
    case reminder, event
}

// Quick-create sheet reachable from the Home dashboard — mirrors web's
// DashboardCreateModal. Lets the user fan the same reminder/event out to
// multiple chats at once (one row inserted per selected conversation).
struct DashboardCreateView: View {
    let type: DashboardCreateType
    let conversations: [ConversationListItem]
    let currentUserId: UUID
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var location = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var includeWhen = true
    @State private var search = ""
    @State private var selected: Set<UUID> = []
    @State private var isSaving = false
    @State private var error: String?

    private var filtered: [ConversationListItem] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { $0.displayName(currentUserId: currentUserId).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(type == .reminder ? "Remind me to…" : "Event name", text: $title)
                    if type == .event {
                        TextField("Description (optional)", text: $description, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("Location (optional)", text: $location)
                    }
                }

                Section(type == .reminder ? "When" : "Date & time (leave off for a plan)") {
                    if type == .event {
                        Toggle("Set a date", isOn: $includeWhen)
                    }
                    if type == .reminder || includeWhen {
                        DatePicker("", selection: $when, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }

                Section {
                    TextField("Search chats…", text: $search)
                    if filtered.isEmpty {
                        Text("No chats found")
                            .font(.subheadline)
                            .foregroundStyle(Color.yaplySecondary)
                    } else {
                        ForEach(filtered) { conv in
                            Button {
                                toggle(conv.id)
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(
                                        url: conv.isGroup ? conv.avatarUrl : conv.otherMember(currentUserId: currentUserId)?.profile.avatarUrl,
                                        name: conv.displayName(currentUserId: currentUserId),
                                        size: 30
                                    )
                                    Text(conv.displayName(currentUserId: currentUserId))
                                        .foregroundStyle(Color.yaplyPrimary)
                                    Spacer()
                                    Image(systemName: selected.contains(conv.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(conv.id) ? Color.yaplyAccent : Color.yaplySecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(selected.isEmpty ? "Chats" : "Chats (\(selected.count) selected)")
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(Color.yaplyDanger)
                }
            }
            .navigationTitle(type == .reminder ? "New Reminder" : "New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Creating…" : "Create") {
                        Task { await save() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func save() async {
        error = nil
        guard !selected.isEmpty else {
            error = "Pick at least one chat"
            return
        }
        isSaving = true
        defer { isSaving = false }

        do {
            switch type {
            case .reminder:
                let repo = ReminderRepository()
                for conversationId in selected {
                    try await repo.createReminder(conversationId: conversationId, userId: currentUserId, message: title, remindAt: when)
                }
            case .event:
                let repo = EventRepository()
                let startsAt = includeWhen ? when : nil
                for conversationId in selected {
                    _ = try await repo.createEvent(
                        conversationId: conversationId,
                        createdBy: currentUserId,
                        name: title,
                        description: description.isEmpty ? nil : description,
                        location: location.isEmpty ? nil : location,
                        status: startsAt != nil ? "confirmed" : "planning",
                        startsAt: startsAt
                    )
                }
            }
            onCreated()
            dismiss()
        } catch {
            self.error = "Something went wrong — try again"
        }
    }
}
