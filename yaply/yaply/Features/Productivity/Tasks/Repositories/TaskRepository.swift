import Foundation

import Foundation
import Supabase
import PostgREST

// Mirrors src/features/commands/handlers/createHandler.ts task creation
struct YaplyTask: Codable, Identifiable {
    let id: UUID
    let conversationId: UUID?
    let createdBy: UUID
    var assignedTo: UUID?
    var title: String
    var description: String?
    var status: String     // "todo" | "in_progress" | "done"
    var priority: String   // "low" | "medium" | "high"
    var dueAt: Date?
    var completedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority
        case conversationId = "conversation_id"
        case createdBy      = "created_by"
        case assignedTo     = "assigned_to"
        case dueAt          = "due_at"
        case completedAt    = "completed_at"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
    }
}

final class TaskRepository {
    func fetchTasks(conversationId: UUID) async throws -> [YaplyTask] {
        return try await supabase
            .from("tasks")
            .select()
            .eq("conversation_id", value: conversationId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func createTask(conversationId: UUID, createdBy: UUID, title: String, priority: String = "medium") async throws -> YaplyTask {
        struct Insert: Encodable {
            let conversation_id: String
            let created_by: String
            let title: String
            let status: String
            let priority: String
        }
        return try await supabase
            .from("tasks")
            .insert(Insert(conversation_id: conversationId.uuidString, created_by: createdBy.uuidString, title: title, status: "todo", priority: priority))
            .select()
            .single()
            .execute()
            .value
    }

    func updateStatus(taskId: UUID, status: String) async throws {
        struct StatusUpdate: Encodable {
            let status: String
            let updated_at: String
        }
        try await supabase
            .from("tasks")
            .update(StatusUpdate(status: status, updated_at: Date().iso8601))
            .eq("id", value: taskId.uuidString)
            .execute()
    }
}
