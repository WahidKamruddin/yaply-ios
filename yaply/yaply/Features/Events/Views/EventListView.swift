import SwiftUI

struct EventListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

    @Environment(AppRouter.self) private var router

    @State private var events: [YaplyEvent] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var eventToDelete: YaplyEvent?
    @State private var createStatus: String = "planning"
    @State private var filter: String = "all"
    @State private var newName = ""
    @State private var newLocation = ""
    @State private var newStartsAt = Date().addingTimeInterval(3600)

    private let repo = EventRepository()

    private var filteredEvents: [YaplyEvent] {
        switch filter {
        case "planning":  return events.filter { $0.isPlanning }
        case "confirmed": return events.filter { $0.isConfirmed }
        default:          return events
        }
    }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if events.isEmpty {
                    emptyState
                } else {
                    Picker("Filter", selection: $filter) {
                        Text("All").tag("all")
                        Text("Planning").tag("planning")
                        Text("Confirmed").tag("confirmed")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if filteredEvents.isEmpty {
                        Spacer()
                        Text("No \(filter) events")
                            .foregroundStyle(Color.yaplySecondary)
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredEvents) { event in
                                Button(action: { router.push(.eventDetail(event)) }) {
                                    EventRowView(event: event, isCurrentUserAdmin: isCurrentUserAdmin, repo: repo, onUpdated: { Task { await load() } })
                                }
                                .buttonStyle(.plain)
                                .yaplyCardStyle()
                                .yaplyCardRowContainer()
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    let canDelete = event.createdBy == currentUserId || isCurrentUserAdmin
                                    let effectiveCanDelete = canDelete && (!event.locked || isCurrentUserAdmin)
                                    Button(role: effectiveCanDelete ? .destructive : .none) {
                                        if effectiveCanDelete { eventToDelete = event }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(effectiveCanDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if isCurrentUserAdmin {
                                        Button {
                                            Task {
                                                try? await repo.setLocked(id: event.id, locked: !event.locked)
                                                await load()
                                            }
                                        } label: {
                                            Label(event.locked ? "Unlock" : "Lock",
                                                  systemImage: event.locked ? "lock.open" : "lock")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { createStatus = "planning"; showCreate = true }) {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .yaplyItemCreated)) { notif in
            guard (notif.userInfo?["type"] as? String) == "events" else { return }
            Task { await load() }
        }
        .yaplyPopup(isPresented: $showCreate) { createSheet }
        .yaplyConfirm(
            isPresented: Binding(get: { eventToDelete != nil }, set: { if !$0 { eventToDelete = nil } }),
            title: "Delete event",
            message: "\"\(eventToDelete?.name ?? "")\" will be permanently deleted. This cannot be undone.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            guard let e = eventToDelete else { return }
            eventToDelete = nil
            Task {
                try? await repo.deleteEvent(id: e.id)
                events.removeAll { $0.id == e.id }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            EmptyStateView(icon: "calendar", title: "No events yet")
            HStack(spacing: 16) {
                Button("+ Plan") {
                    createStatus = "planning"
                    showCreate = true
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.yaplyAccent)
                Button("+ Event") {
                    createStatus = "confirmed"
                    showCreate = true
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.yaplyAccent)
            }
            Spacer()
        }
    }

    private var createSheet: some View {
        YaplySheetScaffold(
            title: createStatus == "planning" ? "New plan" : "New event",
            primaryLabel: "Create",
            primaryEnabled: !newName.isBlank,
            primaryAction: {
                guard !newName.isBlank else { return }
                let name = newName, loc = newLocation, status = createStatus
                let starts = createStatus == "confirmed" ? newStartsAt : nil
                newName = ""; newLocation = ""
                showCreate = false
                Task {
                    try? await repo.createEvent(
                        conversationId: conversationId,
                        createdBy: currentUserId,
                        name: name,
                        location: loc.isEmpty ? nil : loc,
                        status: status,
                        startsAt: starts
                    )
                    await load()
                }
            }
        ) {
            VStack(spacing: 16) {
                Picker("Type", selection: $createStatus) {
                    Text("Planning").tag("planning")
                    Text("Confirmed").tag("confirmed")
                }
                .pickerStyle(.segmented)

                YaplyLabeledField(label: "Name") {
                    TextField("Dinner, trip, movie night…", text: $newName)
                        .yaplyInputStyle()
                }
                YaplyLabeledField(label: "Location (optional)") {
                    TextField("Where?", text: $newLocation)
                        .yaplyInputStyle()
                }
                if createStatus == "confirmed" {
                    YaplyLabeledField(label: "Date & time") {
                        DatePicker("", selection: $newStartsAt, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        events = (try? await repo.fetchEvents(conversationId: conversationId)) ?? []
        isLoading = false
    }
}

private struct EventRowView: View {
    let event: YaplyEvent
    var isCurrentUserAdmin: Bool = false
    var repo: EventRepository? = nil
    var onUpdated: (() -> Void)? = nil

    @State private var showEditStartsAt = false
    @State private var editStartsAt = Date()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(event.isPlanning ? Color.yaplyBackground : Color.yaplyConfirmedGreen)
                    .frame(width: 36, height: 36)
                Image(systemName: event.isPlanning ? "map" : "calendar")
                    .font(.system(size: 14))
                    .foregroundStyle(event.isPlanning ? Color.yaplyAccent : Color.yaplyMint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if event.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    Text(event.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.yaplyPrimary)
                }
                HStack(spacing: 6) {
                    if event.isPlanning {
                        Text("Planning")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yaplyBackground)
                            .foregroundStyle(Color.yaplyAccent)
                            .clipShape(Capsule())
                    }
                    if let starts = event.startsAt, event.isConfirmed {
                        Text(starts.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption)
                            .foregroundStyle(Color.yaplySecondary)
                        if isCurrentUserAdmin {
                            Button(action: {
                                editStartsAt = starts
                                showEditStartsAt = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.yaplySecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("by \(event.creator?.name ?? "Unknown")")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
        .yaplyPopup(isPresented: $showEditStartsAt) {
            YaplySheetScaffold(
                title: "Edit event time",
                primaryLabel: "Save",
                primaryAction: {
                    showEditStartsAt = false
                    Task {
                        try? await repo?.updateStartsAt(eventId: event.id, startsAt: editStartsAt)
                        onUpdated?()
                    }
                }
            ) {
                YaplyLabeledField(label: "Starts at") {
                    DatePicker("", selection: $editStartsAt, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
