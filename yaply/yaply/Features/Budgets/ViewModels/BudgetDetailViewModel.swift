import Foundation
import Supabase

@Observable
@MainActor
final class BudgetDetailViewModel {
    let budgetId: UUID
    let currentUserId: UUID

    private(set) var budget: YaplyBudget?
    private(set) var expenses: [YaplyExpense] = []
    private(set) var settlements: [YaplySettlement] = []
    private(set) var balances: [BudgetBalance] = []
    private(set) var debts: [BudgetDebt] = []
    private(set) var isLoading = false
    /// Set once a successful fetch comes back empty — deleted, or we left the chat.
    private(set) var isGone = false
    var error: String?

    private let repo = BudgetRepository()
    private var realtimeTask: Task<Void, Never>?
    private var realtimeChannel: RealtimeChannelV2?
    private var reconnectToken: UUID?

    init(budgetId: UUID, currentUserId: UUID) {
        self.budgetId = budgetId
        self.currentUserId = currentUserId
    }

    var spent: Decimal { expenses.reduce(0) { $0 + $1.amount } }
    var myNet: Decimal { balances.first { $0.userId == currentUserId }?.net ?? 0 }

    // MARK: Loading

    func load(showSpinner: Bool = true) async {
        if showSpinner && budget == nil { isLoading = true }
        defer { isLoading = false }
        do {
            guard let b = try await repo.fetchBudget(id: budgetId) else {
                // A *successful* empty result is the only thing treated as gone.
                isGone = true
                return
            }
            async let e = repo.fetchExpenses(budgetId: budgetId)
            async let s = repo.fetchSettlements(budgetId: budgetId)
            async let bal = repo.fetchBalances(budgetId: budgetId)
            async let d = repo.fetchDebts(budgetId: budgetId)
            let (ex, st, ba, de) = try await (e, s, bal, d)
            budget = b
            expenses = ex
            settlements = st
            balances = ba
            debts = de
        } catch {
            if !Task.isCancelled { self.error = friendlyBudgetError(error) }
        }
    }

    // MARK: Writes

    /// Runs a write and reloads. Returns the error message instead of setting
    /// `error`, for sheets that show it inline (an alert can't present over them).
    func attempt(_ op: () async throws -> Void) async -> String? {
        do {
            try await op()
            await load(showSpinner: false)
            return nil
        } catch {
            return friendlyBudgetError(error)
        }
    }

    private func perform(_ op: () async throws -> Void) async {
        if let message = await attempt(op) { error = message }
    }

    func saveExpense(_ input: ExpenseFormInput, editing expenseId: UUID?) async -> String? {
        await attempt {
            try await repo.saveExpense(budgetId: budgetId, expenseId: expenseId, input: input)
        }
    }

    func recordSettlement(_ debt: BudgetDebt, amountCents: Int) async -> String? {
        await attempt {
            try await repo.recordSettlement(budgetId: budgetId, from: debt.fromUser, to: debt.toUser, amountCents: amountCents)
        }
    }

    func deleteExpense(_ expense: YaplyExpense) async {
        await perform { try await repo.deleteExpense(id: expense.id) }
    }

    func deleteSettlement(_ settlement: YaplySettlement) async {
        await perform { try await repo.deleteSettlement(id: settlement.id) }
    }

    func setLocked(_ locked: Bool) async {
        await perform { try await repo.setLocked(id: budgetId, locked: locked) }
    }

    func deleteBudget() async -> Bool {
        do {
            try await repo.deleteBudget(id: budgetId)
            return true
        } catch {
            self.error = friendlyBudgetError(error)
            return false
        }
    }

    // MARK: Realtime

    // Only `budgets` is in the realtime publication: every write RPC touches the
    // parent budget's updated_at, so one UPDATE covers expense and settlement
    // changes too. Pure invalidation — the payload is never parsed into state.
    func startRealtime(refetchOnSubscribe: Bool = false) {
        realtimeTask?.cancel()
        RealtimeConnectionMonitor.remove(realtimeChannel)
        realtimeChannel = nil

        let label = "budget-\(budgetId.uuidString)"
        if reconnectToken == nil {
            reconnectToken = RealtimeConnectionMonitor.shared.register(label: label) { [weak self] in
                self?.startRealtime(refetchOnSubscribe: true)
            }
        }

        realtimeTask = Task {
            let channel = await RealtimeConnectionMonitor.channel("budget-\(budgetId.uuidString)-\(UUID().uuidString)")
            guard !Task.isCancelled else { RealtimeConnectionMonitor.remove(channel); return }
            realtimeChannel = channel
            let updates = channel.postgresChange(
                UpdateAction.self, schema: "public", table: "budgets",
                filter: .eq("id", value: budgetId.uuidString)
            )
            // DELETE events carry only the PK and can't be filtered server-side.
            let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "budgets")
            await RealtimeConnectionMonitor.subscribe(channel, label: label)
            // After subscribing, never before — see ChatViewModel.startRealtime.
            if refetchOnSubscribe { await self.load(showSpinner: false) }
            let ownId = budgetId.uuidString.lowercased()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await RealtimeConnectionMonitor.watch(channel, label: label) { [weak self] in
                        self?.startRealtime(refetchOnSubscribe: true)
                    }
                }
                group.addTask { for await _ in updates { await self.load(showSpinner: false) } }
                group.addTask {
                    for await action in deletes where action.oldRecord["id"]?.stringValue?.lowercased() == ownId {
                        await self.load(showSpinner: false)
                    }
                }
            }
        }
    }

    func stopRealtime() {
        RealtimeConnectionMonitor.shared.unregister(reconnectToken)
        reconnectToken = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        RealtimeConnectionMonitor.remove(realtimeChannel)
        realtimeChannel = nil
    }
}
