import SwiftUI

/// One budget: spent vs. cap, my balance, and Expenses | Balances. Loads by id
/// so it always shows the live row (also how a pill deep-links straight here).
struct BudgetDetailView: View {
    let conversationId: UUID
    let currentUserId: UUID
    let members: [MemberSummary]

    @State private var vm: BudgetDetailViewModel
    @State private var tab: Tab = .expenses
    @State private var expenseSheet: ExpenseSheetTarget?
    @State private var settling: BudgetDebt?
    @State private var expenseToDelete: YaplyExpense?
    @State private var settlementToDelete: YaplySettlement?
    @State private var confirmDeleteBudget = false
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case expenses = "Expenses", balances = "Balances" }

    init(budgetId: UUID, conversationId: UUID, currentUserId: UUID, members: [MemberSummary]) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        self.members = members
        _vm = State(initialValue: BudgetDetailViewModel(budgetId: budgetId, currentUserId: currentUserId))
    }

    private var isAdmin: Bool { members.first { $0.userId == currentUserId }?.isAdmin ?? false }
    private var names: BudgetNames { BudgetNames(members: members, currentUserId: currentUserId) }

    var body: some View {
        ZStack {
            Color.yaplyBackground.ignoresSafeArea()
            if vm.isGone {
                EmptyStateView(icon: "dollarsign.circle", title: "This budget was deleted")
            } else if let budget = vm.budget {
                content(budget)
            } else if vm.isLoading {
                ProgressView().tint(Color.yaplyAccent)
            } else if let error = vm.error {
                EmptyStateView(icon: "exclamationmark.triangle", title: error, actionLabel: "Retry") {
                    vm.error = nil
                    Task { await vm.load() }
                }
            }
        }
        .navigationTitle(vm.budget?.name ?? "Budget")
        .navChrome()
        .toolbar { toolbar }
        .task {
            await vm.load()
            vm.startRealtime()
        }
        .onDisappear { vm.stopRealtime() }
        .yaplyPopup(item: $expenseSheet) { target in
            if let budget = vm.budget {
                ExpenseFormSheet(
                    budget: budget,
                    members: members,
                    currentUserId: currentUserId,
                    names: names,
                    expense: target.expense,
                    vm: vm
                )
            }
        }
        .yaplyPopup(item: $settling) { debt in
            if let budget = vm.budget {
                SettleUpSheet(budget: budget, debt: debt, names: names) { cents in
                    await vm.recordSettlement(debt, amountCents: cents)
                }
            }
        }
        .yaplyConfirm(
            isPresented: Binding(get: { expenseToDelete != nil }, set: { if !$0 { expenseToDelete = nil } }),
            title: "Delete expense",
            message: "\"\(expenseToDelete?.description ?? "")\" will be removed and everyone's balances updated.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            guard let e = expenseToDelete else { return }
            Task { await vm.deleteExpense(e) }
        }
        .yaplyConfirm(
            isPresented: Binding(get: { settlementToDelete != nil }, set: { if !$0 { settlementToDelete = nil } }),
            title: "Delete payment",
            message: "This undoes the payment and puts the balance back.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            guard let s = settlementToDelete else { return }
            Task { await vm.deleteSettlement(s) }
        }
        .yaplyConfirm(
            isPresented: $confirmDeleteBudget,
            title: "Delete budget",
            message: "\"\(vm.budget?.name ?? "")\" and all its expenses and payments will be permanently deleted. This cannot be undone.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            Task { if await vm.deleteBudget() { dismiss() } }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { vm.error != nil && vm.budget != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK", role: .cancel) { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let budget = vm.budget, !vm.isGone {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if canWriteExpenses(budget) {
                        Button { expenseSheet = ExpenseSheetTarget(expense: nil) } label: {
                            Image(systemName: "plus").foregroundStyle(Color.yaplyAccent)
                        }
                        .accessibilityLabel("Add expense")
                    }
                    Menu {
                        if isAdmin {
                            Button {
                                Task { await vm.setLocked(!budget.locked) }
                            } label: {
                                Label(budget.locked ? "Unlock" : "Lock", systemImage: budget.locked ? "lock.open" : "lock")
                            }
                        }
                        if canDeleteBudget(budget) {
                            Button(role: .destructive) { confirmDeleteBudget = true } label: {
                                Label("Delete budget", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Color.yaplyAccent)
                    }
                    .disabled(!isAdmin && !canDeleteBudget(budget))
                }
            }
        }
    }

    // MARK: Content

    private func content(_ budget: YaplyBudget) -> some View {
        List {
            summaryCard(budget)
                .yaplyCardStyle()
                .yaplyCardRowContainer()

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .yaplyCardRowContainer()

            switch tab {
            case .expenses: expensesSection(budget)
            case .balances: balancesSection(budget)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.load(showSpinner: false) }
    }

    private func summaryCard(_ budget: YaplyBudget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if budget.locked {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Color.orange)
                }
                Text("Spent").font(.subheadline).foregroundStyle(Color.yaplySecondary)
                Spacer()
                Text(BudgetMoney.format(vm.spent, currency: budget.currency))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(overCap(budget) ? Color.yaplyDanger : Color.yaplyPrimary)
                if let cap = budget.totalAmount {
                    Text("of \(BudgetMoney.format(cap, currency: budget.currency))")
                        .font(.subheadline)
                        .foregroundStyle(Color.yaplySecondary)
                }
            }
            if let cap = budget.totalAmount {
                BudgetCapBar(spent: vm.spent, cap: cap)
            }
            BudgetNetLabel(net: vm.myNet, currency: budget.currency)
                .font(.system(size: 14, weight: .medium))
            Text("by \(budget.creator?.name ?? "Unknown")")
                .font(.caption)
                .foregroundStyle(Color.yaplySecondary)
        }
    }

    @ViewBuilder
    private func expensesSection(_ budget: YaplyBudget) -> some View {
        if vm.expenses.isEmpty {
            Text(canWriteExpenses(budget) ? "No expenses yet. Tap + to add one." : "No expenses yet.")
                .font(.subheadline)
                .foregroundStyle(Color.yaplySecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .yaplyCardRowContainer()
        } else {
            ForEach(vm.expenses) { expense in
                ExpenseRowView(expense: expense, currency: budget.currency, currentUserId: currentUserId, names: names)
                    .yaplyCardStyle()
                    .yaplyCardRowContainer()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canEdit(expense, budget) {
                            Button(role: .destructive) { expenseToDelete = expense } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(Color.yaplyDanger)
                            Button { expenseSheet = ExpenseSheetTarget(expense: expense) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Color.yaplyAccent)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func balancesSection(_ budget: YaplyBudget) -> some View {
        sectionHeader("Who pays whom")
        if vm.debts.isEmpty {
            Text("Everyone's settled up.")
                .font(.subheadline)
                .foregroundStyle(Color.yaplySecondary)
                .yaplyCardRowContainer()
        } else {
            ForEach(vm.debts) { debt in
                HStack(spacing: 6) {
                    Text(names.name(debt.fromUser)).lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(Color.yaplySecondary)
                    Text(names.name(debt.toUser)).lineLimit(1)
                    Spacer()
                    Text(BudgetMoney.format(debt.amount, currency: budget.currency)).fontWeight(.semibold)
                    if debt.fromUser == currentUserId || debt.toUser == currentUserId {
                        Button("Settle up") { settling = debt }
                            .font(.system(size: 13, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(Color.yaplyAccent)
                            .controlSize(.small)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(Color.yaplyPrimary)
                .yaplyCardStyle()
                .yaplyCardRowContainer()
            }
        }

        let nonZero = vm.balances.filter { BudgetMoney.cents($0.net) != 0 }.sorted { $0.net > $1.net }
        if !nonZero.isEmpty {
            sectionHeader("Balances")
            ForEach(nonZero) { b in
                HStack {
                    Text(names.name(b.userId)).foregroundStyle(Color.yaplyPrimary)
                    Spacer()
                    Text(b.net > 0
                         ? "gets back \(BudgetMoney.format(b.net, currency: budget.currency))"
                         : "owes \(BudgetMoney.format(-b.net, currency: budget.currency))")
                        .foregroundStyle(b.net > 0 ? Color.yaplyOnline : Color.yaplyDanger)
                }
                .font(.system(size: 14))
                .yaplyCardRowContainer()
            }
        }

        if !vm.settlements.isEmpty {
            sectionHeader("Payments")
            ForEach(vm.settlements) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(names.name(s.fromUser)) paid \(names.name(s.toUser, object: true))")
                            .foregroundStyle(Color.yaplyPrimary)
                        Text(s.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    Spacer()
                    Text(BudgetMoney.format(s.amount, currency: budget.currency)).fontWeight(.semibold)
                }
                .font(.system(size: 14))
                .yaplyCardRowContainer()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if s.createdBy == currentUserId || isAdmin {
                        Button(role: .destructive) { settlementToDelete = s } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Color.yaplyDanger)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.yaplySecondary)
            .padding(.top, 8)
            .yaplyCardRowContainer()
    }

    // MARK: Permissions (decorative — the RPCs and trigger enforce them)

    private func canWriteExpenses(_ budget: YaplyBudget) -> Bool { !budget.locked || isAdmin }

    private func canEdit(_ expense: YaplyExpense, _ budget: YaplyBudget) -> Bool {
        canWriteExpenses(budget) && (isAdmin || expense.createdBy == currentUserId || expense.paidBy == currentUserId)
    }

    private func canDeleteBudget(_ budget: YaplyBudget) -> Bool {
        (budget.createdBy == currentUserId && !budget.locked) || isAdmin
    }

    private func overCap(_ budget: YaplyBudget) -> Bool {
        guard let cap = budget.totalAmount else { return false }
        return vm.spent > cap
    }
}

/// Identifiable wrapper so one popup handles both add (nil) and edit.
struct ExpenseSheetTarget: Identifiable {
    let id = UUID()
    let expense: YaplyExpense?
}

private struct ExpenseRowView: View {
    let expense: YaplyExpense
    let currency: String
    let currentUserId: UUID
    let names: BudgetNames

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.description)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.yaplyPrimary)
                    .lineLimit(2)
                Text("\(names.name(expense.paidBy)) paid · \(expense.category.capitalized) · \(BudgetDate.short(expense.spentOn))")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
                mine.font(.caption)
            }
            Spacer()
            Text(BudgetMoney.format(expense.amount, currency: currency))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.yaplyPrimary)
        }
    }

    @ViewBuilder
    private var mine: some View {
        let myShare = expense.share(of: currentUserId)
        let iPaid = expense.paidBy == currentUserId
        let lent = expense.amount - myShare
        if iPaid && lent > 0 {
            Text("you lent \(BudgetMoney.format(lent, currency: currency))").foregroundStyle(Color.yaplyOnline)
        } else if !iPaid && myShare > 0 {
            Text("you owe \(BudgetMoney.format(myShare, currency: currency))").foregroundStyle(Color.yaplyDanger)
        } else if iPaid {
            Text("just you").foregroundStyle(Color.yaplySecondary)
        } else {
            Text("not involved").foregroundStyle(Color.yaplySecondary)
        }
    }
}

// MARK: - Shared bits (list + detail)

struct BudgetCapBar: View {
    let spent: Decimal
    let cap: Decimal

    var body: some View {
        let fraction = cap > 0 ? min(1, NSDecimalNumber(decimal: spent / cap).doubleValue) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.yaplyTintStrong)
                Capsule()
                    .fill(spent > cap ? Color.yaplyDanger : Color.yaplyAccent)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("\(Int(fraction * 100)) percent of budget spent")
    }
}

/// The viewer's own position: owed, owes, or settled.
struct BudgetNetLabel: View {
    let net: Decimal
    let currency: String

    var body: some View {
        if BudgetMoney.cents(net) == 0 {
            Text("You're all settled up").foregroundStyle(Color.yaplySecondary)
        } else if net > 0 {
            Text("You're owed \(BudgetMoney.format(net, currency: currency))").foregroundStyle(Color.yaplyOnline)
        } else {
            Text("You owe \(BudgetMoney.format(-net, currency: currency))").foregroundStyle(Color.yaplyDanger)
        }
    }
}

/// Names in budget copy. People who left the chat keep their balances but
/// aren't in `members`, so they get a neutral label rather than a raw id.
struct BudgetNames {
    let members: [MemberSummary]
    let currentUserId: UUID

    /// `object`: mid-sentence, so the viewer reads "you" ("Alice paid you").
    func name(_ userId: UUID?, object: Bool = false) -> String {
        guard let userId else { return "Someone" }
        if userId == currentUserId { return object ? "you" : "You" }
        guard let p = members.first(where: { $0.userId == userId })?.profile else { return "Former member" }
        if let display = p.displayName, !display.isEmpty { return display }
        return p.username
    }
}

nonisolated enum BudgetDate {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local "YYYY-MM-DD" for `spent_on`.
    static func string(from date: Date) -> String { parser.string(from: date) }
    static func date(from string: String) -> Date? { parser.date(from: string) }

    static func short(_ ymd: String) -> String {
        guard let d = date(from: ymd) else { return ymd }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}
