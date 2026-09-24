import SwiftUI

struct BudgetListView: View {
    let conversationId: UUID
    let currentUserId: UUID
    var members: [MemberSummary] = []
    var isCurrentUserAdmin: Bool = false
    /// Set when opened from Home: that budget's detail page is pushed once
    /// the list has loaded.
    var focusItemId: UUID? = nil

    @Environment(AppRouter.self) private var router
    @State private var budgets: [YaplyBudget] = []
    @State private var overviews: [UUID: BudgetOverview] = [:]
    @State private var eventNames: [UUID: String] = [:]
    @State private var events: [YaplyEvent] = []
    @State private var didApplyFocus = false
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var budgetToDelete: YaplyBudget?
    @State private var budgetToLink: YaplyBudget?
    @State private var newName = ""
    @State private var newCap = ""
    @State private var newCurrency = "USD"
    @State private var createError: String?

    private let repo = BudgetRepository()
    private let eventRepo = EventRepository()

    /// Blank = no cap; otherwise it must parse.
    private var newCapCents: Int?? {
        let t = newCap.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        return BudgetMoney.parseCents(t).map { .some($0) }
    }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading && budgets.isEmpty {
                    Spacer()
                    ProgressView().tint(Color.yaplyAccent)
                    Spacer()
                } else if budgets.isEmpty {
                    Spacer()
                    EmptyStateView(icon: "dollarsign.circle", title: "No budgets yet", actionLabel: "New budget") {
                        showCreate = true
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(budgets) { budget in
                            Button {
                                open(budget)
                            } label: {
                                BudgetRowView(
                                    budget: budget,
                                    overview: overviews[budget.id],
                                    linkedEventName: budget.eventId.flatMap { eventNames[$0] }
                                )
                            }
                            .buttonStyle(.plain)
                            .yaplyCardStyle()
                            .yaplyCardRowContainer()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                let canDelete = (budget.createdBy == currentUserId && !budget.locked) || isCurrentUserAdmin
                                Button(role: canDelete ? .destructive : .none) {
                                    if canDelete { budgetToDelete = budget }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(canDelete ? Color.yaplyDanger : Color(UIColor.systemGray4))

                                // Link/Unlink are gated like Delete rather than left
                                // open to any member.
                                if budget.createdBy == currentUserId || isCurrentUserAdmin {
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
                    .refreshable { await load() }
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
                .accessibilityLabel("New budget")
            }
        }
        // Re-runs on return from a detail page, so spent / my balance stay fresh.
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
            message: "\"\(budgetToDelete?.name ?? "")\" and all its expenses and payments will be permanently deleted. This cannot be undone.",
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
            primaryEnabled: !newName.isBlank && newCapCents != nil,
            primaryAction: create
        ) {
            VStack(spacing: 16) {
                YaplyLabeledField(label: "Budget name") {
                    TextField("Trip, dinner, group gift…", text: $newName)
                        .yaplyInputStyle()
                }
                YaplyLabeledField(label: "Spending cap (optional)") {
                    TextField("No cap", text: $newCap)
                        .keyboardType(.decimalPad)
                        .yaplyInputStyle()
                }
                YaplyLabeledField(label: "Currency") {
                    Picker("Currency", selection: $newCurrency) {
                        ForEach(BudgetMoney.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if let createError {
                    Text(createError)
                        .font(.footnote)
                        .foregroundStyle(Color.yaplyDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func create() {
        guard !newName.isBlank, let capCents = newCapCents else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = capCents.map { BudgetMoney.decimal(cents: $0) }
        let currency = newCurrency
        createError = nil
        Task {
            do {
                _ = try await repo.createBudget(conversationId: conversationId, createdBy: currentUserId, name: name, totalAmount: cap, currency: currency)
                newName = ""; newCap = ""
                showCreate = false
                await load()
            } catch {
                createError = friendlyBudgetError(error)
            }
        }
    }

    private func open(_ budget: YaplyBudget) {
        router.push(.budgetDetail(budgetId: budget.id, conversationId: conversationId, members: members))
    }

    private func load() async {
        isLoading = true
        async let budgetFetch = repo.fetchBudgets(conversationId: conversationId)
        async let overviewFetch = repo.fetchOverviews(conversationId: conversationId)
        async let eventFetch = eventRepo.fetchEvents(conversationId: conversationId)
        budgets = (try? await budgetFetch) ?? budgets
        overviews = (try? await overviewFetch) ?? overviews
        events = (try? await eventFetch) ?? events
        // One dictionary, not a per-row scan of `events` (yaply-ios#31).
        eventNames = Dictionary(events.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        isLoading = false

        if let focusItemId, !didApplyFocus, let match = budgets.first(where: { $0.id == focusItemId }) {
            didApplyFocus = true
            open(match)
        }
    }
}

private struct BudgetRowView: View {
    let budget: YaplyBudget
    let overview: BudgetOverview?
    let linkedEventName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            .lineLimit(1)
                    }
                    if let linkedEventName {
                        Label(linkedEventName, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(Color.yaplyAccent)
                    } else {
                        Text("by \(budget.creator?.name ?? "Unknown")")
                            .font(.caption)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(BudgetMoney.format(overview?.spent ?? 0, currency: budget.currency))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.yaplyAccent)
                    Text(budget.totalAmount.map { "of \(BudgetMoney.format($0, currency: budget.currency))" } ?? "spent")
                        .font(.caption)
                        .foregroundStyle(Color.yaplySecondary)
                }
            }
            if let cap = budget.totalAmount {
                BudgetCapBar(spent: overview?.spent ?? 0, cap: cap)
            }
            if let overview {
                BudgetNetLabel(net: overview.myNet, currency: budget.currency)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
