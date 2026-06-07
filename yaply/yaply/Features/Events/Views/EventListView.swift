import SwiftUI

struct EventListView: View {
    let conversationId: UUID
    let currentUserId: UUID

    @State private var events: [YaplyEvent] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var eventToDelete: YaplyEvent?
    @State private var createStatus: String = "planning"
    @State private var newName = ""
    @State private var newLocation = ""
    @State private var newStartsAt = Date().addingTimeInterval(3600)
    @State private var showDatePicker = false

    private let repo = EventRepository()

    private var confirmed: [YaplyEvent] { events.filter { $0.isConfirmed } }
    private var planning: [YaplyEvent] { events.filter { $0.isPlanning } }

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
                    List {
                        if !confirmed.isEmpty {
                            Section("Confirmed") {
                                ForEach(confirmed) { event in
                                    EventRowView(event: event)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if event.createdBy == currentUserId {
                                                Button(role: .destructive) {
                                                    eventToDelete = event
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                        }
                                }
                            }
                        }
                        if !planning.isEmpty {
                            Section("Planning") {
                                ForEach(planning) { event in
                                    EventRowView(event: event)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if event.createdBy == currentUserId {
                                                Button(role: .destructive) {
                                                    eventToDelete = event
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showCreate = true }) {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .alert("Delete Event", isPresented: Binding(
            get: { eventToDelete != nil },
            set: { if !$0 { eventToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let e = eventToDelete else { return }
                eventToDelete = nil
                Task {
                    try? await repo.deleteEvent(id: e.id)
                    events.removeAll { $0.id == e.id }
                }
            }
            Button("Cancel", role: .cancel) { eventToDelete = nil }
        } message: {
            Text("\"\(eventToDelete?.name ?? "")\" will be permanently deleted.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar")
                .font(.system(size: 40))
                .foregroundStyle(Color.yaplySecondary)
            Text("No events yet")
                .foregroundStyle(Color.yaplySecondary)
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
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $createStatus) {
                        Text("Planning").tag("planning")
                        Text("Confirmed").tag("confirmed")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Details") {
                    TextField("Name", text: $newName)
                    TextField("Location (optional)", text: $newLocation)
                }
                if createStatus == "confirmed" {
                    Section("Date & Time") {
                        DatePicker("Starts at", selection: $newStartsAt, displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            .navigationTitle(createStatus == "planning" ? "New Plan" : "New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !newName.isBlank else { return }
                        Task {
                            try? await repo.createEvent(
                                conversationId: conversationId,
                                createdBy: currentUserId,
                                name: newName,
                                location: newLocation.isEmpty ? nil : newLocation,
                                status: createStatus,
                                startsAt: createStatus == "confirmed" ? newStartsAt : nil
                            )
                            newName = ""
                            newLocation = ""
                            showCreate = false
                            await load()
                        }
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

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(event.isPlanning ? Color(red: 0.929, green: 0.945, blue: 0.980) : Color(red: 0.9, green: 0.97, blue: 0.9))
                    .frame(width: 36, height: 36)
                Image(systemName: event.isPlanning ? "map" : "calendar")
                    .font(.system(size: 14))
                    .foregroundStyle(event.isPlanning ? Color.yaplyAccent : Color.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.yaplyPrimary)
                HStack(spacing: 6) {
                    Text(event.isPlanning ? "Planning" : "Confirmed")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(event.isPlanning
                            ? Color(red: 0.929, green: 0.945, blue: 0.980)
                            : Color(red: 0.9, green: 0.97, blue: 0.9))
                        .foregroundStyle(event.isPlanning ? Color.yaplyAccent : Color.green)
                        .clipShape(Capsule())
                    if let starts = event.startsAt, event.isConfirmed {
                        Text(starts.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
