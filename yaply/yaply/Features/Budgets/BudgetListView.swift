import SwiftUI

struct BudgetListView: View {
    let conversationId: UUID
    let currentUserId: UUID

    @State private var budgets: [YaplyBudget] = []
    @State private var events: [YaplyEvent] = []
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var budgetToDelete: YaplyBudget?
    @State private var budgetToLink: YaplyBudget?
    @State private var newName = ""
    @State private var newAmount = ""
    @State private var newCurrency = "USD"

    private let repo = BudgetRepository()
    private let eventRepo = EventRepository()

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if budgets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.yaplySecondary)
                        Text("No budgets yet")
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(budgets) { budget in
                            BudgetRowView(budget: budget, events: events)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if budget.createdBy == currentUserId {
                                        Button(role: .destructive) {
                                            budgetToDelete = budget
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    if budget.eventId != nil {
                                        Button {
                                            Task {
                                                try? await repo.unlinkFromEvent(budgetId: budget.id)
                                                await load()
                                            }
                                        } label: {
                                            Label("Unlink", systemImage: "link.badge.minus")
                                        }
                                        .tint(.orange)
                                    } else {
                                        Button {
                                            budgetToLink = budget
                                        } label: {
                                            Label("Link Event", systemImage: "link")
                                        }
                                        .tint(Color.yaplyAccent)
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle("Budgets")
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
        .onReceive(NotificationCenter.default.publisher(for: .yaplyItemCreated)) { notif in
            guard (notif.userInfo?["type"] as? String) == "budgets" else { return }
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .sheet(item: $budgetToLink) { budget in
            EventLinkPickerSheet(
                title: "Link \"\(budget.name)\"",
                events: events,
                onSelect: { event in
                    Task {
                        try? await repo.linkToEvent(budgetId: budget.id, eventId: event.id)
                        budgetToLink = nil
                        await load()
                    }
                },
                onCancel: { budgetToLink = nil }
            )
        }
        .alert("Delete Budget", isPresented: Binding(
            get: { budgetToDelete != nil },
            set: { if !$0 { budgetToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let b = budgetToDelete else { return }
                budgetToDelete = nil
                Task {
                    try? await repo.deleteBudget(id: b.id)
                    budgets.removeAll { $0.id == b.id }
                }
            }
            Button("Cancel", role: .cancel) { budgetToDelete = nil }
        } message: {
            Text("\"\(budgetToDelete?.name ?? "")\" and all its expenses will be permanently deleted.")
        }
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Budget name", text: $newName)
                    TextField("Total amount", text: $newAmount)
                        .keyboardType(.decimalPad)
                    Picker("Currency", selection: $newCurrency) {
                        Text("USD").tag("USD")
                        Text("EUR").tag("EUR")
                        Text("GBP").tag("GBP")
                        Text("CAD").tag("CAD")
                    }
                }
            }
            .navigationTitle("New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !newName.isBlank, let amount = Double(newAmount), amount > 0 else { return }
                        Task {
                            try? await repo.createBudget(conversationId: conversationId, createdBy: currentUserId, name: newName, totalAmount: amount, currency: newCurrency)
                            newName = ""
                            newAmount = ""
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
        async let budgetFetch = repo.fetchBudgets(conversationId: conversationId)
        async let eventFetch  = eventRepo.fetchEvents(conversationId: conversationId)
        budgets = (try? await budgetFetch) ?? []
        events  = (try? await eventFetch)  ?? []
        isLoading = false
    }
}

private struct BudgetRowView: View {
    let budget: YaplyBudget
    let events: [YaplyEvent]

    private var linkedEventName: String? {
        guard let eid = budget.eventId else { return nil }
        return events.first { $0.id == eid }?.name
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.9, green: 0.97, blue: 0.92))
                    .frame(width: 36, height: 36)
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(budget.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.yaplyPrimary)
                if let eventName = linkedEventName {
                    Label(eventName, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(Color.yaplyAccent)
                } else {
                    HStack(spacing: 4) {
                        Text("by \(budget.creator?.name ?? "Unknown")")
                        Text("·").foregroundStyle(Color.yaplySecondary.opacity(0.4))
                        Text("\(budget.currency) \(String(format: "%.2f", budget.totalAmount))")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
