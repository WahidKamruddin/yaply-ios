import Foundation
import Supabase
import PostgREST

// Budgets are Splitwise-style shared expenses. The contract lives in ../CLAUDE.md
// ("Budgets (shared expenses)"): expenses, shares and settlements are written
// only through RPCs, shares are stored per person in exact cents, and balances /
// "who pays whom" are computed server-side. iOS renders them; it never splits
// or simplifies locally (the equal-split preview in the form is display only).

struct YaplyBudget: Codable, Identifiable, Hashable {
    let id: UUID
    let conversationId: UUID
    var name: String
    /// nil = no spending cap.
    var totalAmount: Decimal?
    var currency: String
    let createdBy: UUID
    let createdAt: Date
    var locked: Bool
    var creator: CreatorProfile?
    var eventId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, name, currency, creator, locked
        case conversationId = "conversation_id"
        case totalAmount    = "total_amount"
        case createdBy      = "created_by"
        case createdAt      = "created_at"
        case eventId        = "event_id"
    }
}

struct ExpenseShare: Codable, Hashable {
    let userId: UUID
    let amount: Decimal

    enum CodingKeys: String, CodingKey {
        case amount
        case userId = "user_id"
    }
}

struct YaplyExpense: Codable, Identifiable, Hashable {
    let id: UUID
    let budgetId: UUID
    let paidBy: UUID
    /// Who logged it; nil if their account was deleted.
    let createdBy: UUID?
    let description: String
    let amount: Decimal
    let category: String
    /// "equal" | "exact"
    let splitMode: String
    /// Raw "YYYY-MM-DD" from the `date` column (the default decoder doesn't
    /// parse bare dates, same as `Profile.birthdate`).
    let spentOn: String
    let createdAt: Date
    let shares: [ExpenseShare]

    enum CodingKeys: String, CodingKey {
        case id, description, amount, category, shares
        case budgetId  = "budget_id"
        case paidBy    = "paid_by"
        case createdBy = "created_by"
        case splitMode = "split_mode"
        case spentOn   = "spent_on"
        case createdAt = "created_at"
    }

    func share(of userId: UUID) -> Decimal {
        shares.first { $0.userId == userId }?.amount ?? 0
    }
}

/// "fromUser paid toUser back `amount`".
struct YaplySettlement: Codable, Identifiable, Hashable {
    let id: UUID
    let budgetId: UUID
    let fromUser: UUID
    let toUser: UUID
    let amount: Decimal
    let createdBy: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, amount
        case budgetId  = "budget_id"
        case fromUser  = "from_user"
        case toUser    = "to_user"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

struct BudgetBalance: Codable, Identifiable, Hashable {
    var id: UUID { userId }
    let userId: UUID
    let paid: Decimal
    let owed: Decimal
    let settledOut: Decimal
    let settledIn: Decimal
    /// Positive = is owed money.
    let net: Decimal

    enum CodingKeys: String, CodingKey {
        case paid, owed, net
        case userId     = "user_id"
        case settledOut = "settled_out"
        case settledIn  = "settled_in"
    }
}

struct BudgetDebt: Codable, Identifiable, Hashable {
    var id: String { "\(fromUser)-\(toUser)" }
    let fromUser: UUID
    let toUser: UUID
    let amount: Decimal

    enum CodingKeys: String, CodingKey {
        case amount
        case fromUser = "from_user"
        case toUser   = "to_user"
    }
}

struct BudgetOverview: Codable, Hashable {
    let budgetId: UUID
    let spent: Decimal
    let myNet: Decimal

    enum CodingKeys: String, CodingKey {
        case spent
        case budgetId = "budget_id"
        case myNet    = "my_net"
    }
}

final class BudgetRepository {
    // MARK: Budgets

    func fetchBudgets(conversationId: UUID) async throws -> [YaplyBudget] {
        return try await supabase
            .from("budgets")
            .select("*, creator:profiles!budgets_created_by_fkey(display_name, username)")
            .eq("conversation_id", value: conversationId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// nil when the budget is gone (deleted, or no longer visible to us).
    func fetchBudget(id: UUID) async throws -> YaplyBudget? {
        let rows: [YaplyBudget] = try await supabase
            .from("budgets")
            .select("*, creator:profiles!budgets_created_by_fkey(display_name, username)")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Spent and my own balance for every budget in the conversation, in one call.
    func fetchOverviews(conversationId: UUID) async throws -> [UUID: BudgetOverview] {
        struct Params: Encodable { let p_conversation_id: String }
        let rows: [BudgetOverview] = try await supabase
            .rpc("get_budget_overviews", params: Params(p_conversation_id: conversationId.uuidString))
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.budgetId, $0) })
    }

    func createBudget(conversationId: UUID, createdBy: UUID, name: String, totalAmount: Decimal?, currency: String = "USD", eventId: UUID? = nil) async throws -> YaplyBudget {
        struct Insert: Encodable {
            let conversation_id: String
            let created_by: String
            let name: String
            let total_amount: Decimal?
            let currency: String
            let event_id: String?

            // Synthesized Encodable drops nil optionals; send an explicit null
            // so "no cap" is unambiguous.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(conversation_id, forKey: .conversation_id)
                try c.encode(created_by, forKey: .created_by)
                try c.encode(name, forKey: .name)
                try c.encode(total_amount, forKey: .total_amount)
                try c.encode(currency, forKey: .currency)
                try c.encodeIfPresent(event_id, forKey: .event_id)
            }
            enum CodingKeys: String, CodingKey {
                case conversation_id, created_by, name, total_amount, currency, event_id
            }
        }
        let budget: YaplyBudget = try await supabase
            .from("budgets")
            .insert(Insert(conversation_id: conversationId.uuidString, created_by: createdBy.uuidString, name: name, total_amount: totalAmount, currency: currency, event_id: eventId?.uuidString))
            .select()
            .single()
            .execute()
            .value
        await MessageRepository.postItemCreated(conversationId: conversationId, senderId: createdBy, item: SystemItem(kind: .budget, id: budget.id, title: name))
        return budget
    }

    func deleteBudget(id: UUID) async throws {
        try await supabase
            .from("budgets")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    func linkToEvent(budgetId: UUID, eventId: UUID) async throws {
        struct Update: Encodable { let event_id: String }
        try await supabase
            .from("budgets")
            .update(Update(event_id: eventId.uuidString))
            .eq("id", value: budgetId.uuidString)
            .execute()
    }

    func unlinkFromEvent(budgetId: UUID) async throws {
        // Explicit AnyJSON.null rather than an Encodable struct holding an
        // Optional: JSONEncoder omits nil Optionals, so this would PATCH an
        // empty body and silently never clear the column.
        let payload: [String: AnyJSON] = ["event_id": .null]
        try await supabase
            .from("budgets")
            .update(payload)
            .eq("id", value: budgetId.uuidString)
            .execute()
    }

    func setLocked(id: UUID, locked: Bool) async throws {
        struct Update: Encodable { let locked: Bool }
        try await supabase
            .from("budgets")
            .update(Update(locked: locked))
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: Reads

    func fetchExpenses(budgetId: UUID) async throws -> [YaplyExpense] {
        return try await supabase
            .from("expenses")
            .select("*, shares:expense_shares(user_id, amount)")
            .eq("budget_id", value: budgetId.uuidString)
            .order("spent_on", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchSettlements(budgetId: UUID) async throws -> [YaplySettlement] {
        return try await supabase
            .from("settlements")
            .select()
            .eq("budget_id", value: budgetId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchBalances(budgetId: UUID) async throws -> [BudgetBalance] {
        struct Params: Encodable { let p_budget_id: String }
        return try await supabase
            .rpc("get_budget_balances", params: Params(p_budget_id: budgetId.uuidString))
            .execute()
            .value
    }

    func fetchDebts(budgetId: UUID) async throws -> [BudgetDebt] {
        struct Params: Encodable { let p_budget_id: String }
        return try await supabase
            .rpc("get_budget_debts", params: Params(p_budget_id: budgetId.uuidString))
            .execute()
            .value
    }

    // MARK: Writes (RPC only — the tables reject direct writes)

    /// Insert (expenseId nil) or edit. Equal: `participants`; exact: `exactCents`.
    func saveExpense(budgetId: UUID, expenseId: UUID?, input: ExpenseFormInput) async throws {
        nonisolated struct Params: Encodable {
            let p_budget_id: String
            let p_expense_id: String?
            let p_description: String
            let p_amount: Decimal
            let p_category: String
            let p_paid_by: String
            let p_split_mode: String
            let p_participants: [String]
            let p_exact: [String: Decimal]?
            let p_spent_on: String?

            // p_expense_id has no SQL default, so PostgREST needs an explicit
            // null to resolve the function; synthesized Encodable would drop it.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_budget_id, forKey: .p_budget_id)
                try c.encode(p_expense_id, forKey: .p_expense_id)
                try c.encode(p_description, forKey: .p_description)
                try c.encode(p_amount, forKey: .p_amount)
                try c.encode(p_category, forKey: .p_category)
                try c.encode(p_paid_by, forKey: .p_paid_by)
                try c.encode(p_split_mode, forKey: .p_split_mode)
                try c.encode(p_participants, forKey: .p_participants)
                try c.encodeIfPresent(p_exact, forKey: .p_exact)
                try c.encodeIfPresent(p_spent_on, forKey: .p_spent_on)
            }
            enum CodingKeys: String, CodingKey {
                case p_budget_id, p_expense_id, p_description, p_amount, p_category,
                     p_paid_by, p_split_mode, p_participants, p_exact, p_spent_on
            }
        }
        let exact = input.exactCents.map { dict in
            Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString.lowercased(), BudgetMoney.decimal(cents: $0.value)) })
        }
        let isEqual = input.splitMode == "equal"
        try await supabase
            .rpc("save_expense", params: Params(
                p_budget_id: budgetId.uuidString,
                p_expense_id: expenseId?.uuidString,
                p_description: input.description.trimmingCharacters(in: .whitespacesAndNewlines),
                p_amount: BudgetMoney.decimal(cents: input.amountCents),
                p_category: input.category,
                p_paid_by: input.paidBy.uuidString,
                p_split_mode: input.splitMode,
                p_participants: isEqual ? input.participants.map(\.uuidString) : [],
                p_exact: isEqual ? nil : exact,
                p_spent_on: input.spentOn
            ))
            .execute()
    }

    func deleteExpense(id: UUID) async throws {
        struct Params: Encodable { let p_expense_id: String }
        try await supabase
            .rpc("delete_expense", params: Params(p_expense_id: id.uuidString))
            .execute()
    }

    func recordSettlement(budgetId: UUID, from: UUID, to: UUID, amountCents: Int) async throws {
        struct Params: Encodable {
            let p_budget_id: String
            let p_from: String
            let p_to: String
            let p_amount: Decimal
        }
        try await supabase
            .rpc("record_settlement", params: Params(
                p_budget_id: budgetId.uuidString,
                p_from: from.uuidString,
                p_to: to.uuidString,
                p_amount: BudgetMoney.decimal(cents: amountCents)
            ))
            .execute()
    }

    func deleteSettlement(id: UUID) async throws {
        struct Params: Encodable { let p_settlement_id: String }
        try await supabase
            .rpc("delete_settlement", params: Params(p_settlement_id: id.uuidString))
            .execute()
    }
}

/// Maps the RPCs' plain-text Postgres errors to what the UI shows.
func friendlyBudgetError(_ error: Error) -> String {
    let message = (error as? PostgrestError)?.message ?? error.localizedDescription
    if message == "budget locked" { return "This budget is locked by an admin." }
    return message.isEmpty ? "Something went wrong. Try again." : message
}
