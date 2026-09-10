import SwiftUI

struct BudgetListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var isCurrentUserAdmin: Bool = false

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
                    EmptyStateView(icon: "dollarsign.circle", title: "No budgets yet")
                    Spacer()
                } else {
                    List {
                        ForEach(budgets) { budget in
                            BudgetRowView(budget: budget, events: events)
                                .yaplyCardStyle()
                                .yaplyCardRowContainer()
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    let canDelete = budget.createdBy == currentUserId || isCurrentUserAdmin
                                    let effectiveCanDelete = canDelete && (!budget.locked || isCurrentUserAdmin)
                                    Button(role: effectiveCanDelete ? .destructive : .none) {
                                        if effectiveCanDelete { budgetToDelete = budget }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(effectiveCanDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))

                                    // Link/Unlink are member-mutating actions on a shared
                                    // budget — gate them the same as Delete, not left open
                                    // to any member (RLS silently rejects non-creator/admin
                                    // updates, which previously failed with no feedback).
                                    if canDelete {
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
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if isCurrentUserAdmin {
                                        Button {
                                            Task {
                                                try? await repo.setLocked(id: budget.id, locked: !budget.locked)
                                                await load()
                                            }
                                        } label: {
                                            Label(budget.locked ? "Unlock" : "Lock",
                                                  systemImage: budget.locked ? "lock.open" : "lock")
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
        .yaplyPopup(isPresented: $showCreate) {
            createSheet
        }
        .yaplyPopup(item: $budgetToLink) { budget in
            EventLinkPickerSheet(
                title: "Link \"\(budget.name)\"",
                events: events,
                onSelect: { event in
                    Task {
                        try? await repo.linkToEvent(budgetId: budget.id, eventId: event.id)
                        budgetToLink = nil
                        await load()
                    }
                }
            )
        }
        .yaplyConfirm(
            isPresented: Binding(get: { budgetToDelete != nil }, set: { if !$0 { budgetToDelete = nil } }),
            title: "Delete budget",
            message: "\"\(budgetToDelete?.name ?? "")\" and all its expenses will be permanently deleted. This cannot be undone.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            guard let b = budgetToDelete else { return }
            budgetToDelete = nil
            Task {
                try? await repo.deleteBudget(id: b.id)
                budgets.removeAll { $0.id == b.id }
            }
        }
    }

    private var createSheet: some View {
        YaplySheetScaffold(
            title: "New budget",
            primaryLabel: "Create",
            primaryEnabled: !newName.isBlank && (Double(newAmount) ?? 0) > 0,
            primaryAction: {
                guard !newName.isBlank, let amount = Double(newAmount), amount > 0 else { return }
                let name = newName, currency = newCurrency
                newName = ""; newAmount = ""
                showCreate = false
                Task {
                    try? await repo.createBudget(conversationId: conversationId, createdBy: currentUserId, name: name, totalAmount: amount, currency: currency)
                    await load()
                }
            }
        ) {
            VStack(spacing: 16) {
                YaplyLabeledField(label: "Budget name") {
                    TextField("Trip, dinner, group gift…", text: $newName)
                        .yaplyInputStyle()
                }
                YaplyLabeledField(label: "Total amount") {
                    TextField("0.00", text: $newAmount)
                        .keyboardType(.decimalPad)
                        .yaplyInputStyle()
                }
                YaplyLabeledField(label: "Currency") {
                    Picker("Currency", selection: $newCurrency) {
                        Text("USD").tag("USD")
                        Text("EUR").tag("EUR")
                        Text("GBP").tag("GBP")
                        Text("CAD").tag("CAD")
                    }
                    .pickerStyle(.segmented)
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
                    .fill(Color.yaplyConfirmedGreen)
                    .frame(width: 36, height: 36)
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yaplyMint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if budget.locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    Text(budget.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.yaplyPrimary)
                }
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
        .padding(.vertical, 4)
    }
}
