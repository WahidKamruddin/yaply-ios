import Foundation
import Supabase
import PostgREST

struct YaplyBudget: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID
    var name: String
    var totalAmount: Double
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

struct YaplyExpense: Codable, Identifiable {
    let id: UUID
    let budgetId: UUID
    let paidBy: UUID
    let description: String
    let amount: Double
    let category: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, description, amount, category
        case budgetId  = "budget_id"
        case paidBy    = "paid_by"
        case createdAt = "created_at"
    }
}

final class BudgetRepository {
    func fetchBudgets(conversationId: UUID) async throws -> [YaplyBudget] {
        return try await supabase
            .from("budgets")
            .select("*, creator:profiles!budgets_created_by_fkey(display_name, username)")
            .eq("conversation_id", value: conversationId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func createBudget(conversationId: UUID, createdBy: UUID, name: String, totalAmount: Double, currency: String = "USD", eventId: UUID? = nil) async throws -> YaplyBudget {
        struct Insert: Encodable {
            let conversation_id: String
            let created_by: String
            let name: String
            let total_amount: Double
            let currency: String
            let event_id: String?
        }
        return try await supabase
            .from("budgets")
            .insert(Insert(conversation_id: conversationId.uuidString, created_by: createdBy.uuidString, name: name, total_amount: totalAmount, currency: currency, event_id: eventId?.uuidString))
            .select()
            .single()
            .execute()
            .value
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
        struct Update: Encodable { let event_id: String? }
        try await supabase
            .from("budgets")
            .update(Update(event_id: nil))
            .eq("id", value: budgetId.uuidString)
            .execute()
    }

    func fetchExpenses(budgetId: UUID) async throws -> [YaplyExpense] {
        return try await supabase
            .from("expenses")
            .select()
            .eq("budget_id", value: budgetId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func setLocked(id: UUID, locked: Bool) async throws {
        struct Update: Encodable { let locked: Bool }
        try await supabase
            .from("budgets")
            .update(Update(locked: locked))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func addExpense(budgetId: UUID, paidBy: UUID, description: String, amount: Double, category: String = "other", splitBetween: [UUID] = []) async throws -> YaplyExpense {
        struct Insert: Encodable {
            let budget_id: String
            let paid_by: String
            let description: String
            let amount: Double
            let category: String
            let split_between: [String]
        }
        return try await supabase
            .from("expenses")
            .insert(Insert(budget_id: budgetId.uuidString, paid_by: paidBy.uuidString, description: description, amount: amount, category: category, split_between: splitBetween.map(\.uuidString)))
            .select()
            .single()
            .execute()
            .value
    }
}
