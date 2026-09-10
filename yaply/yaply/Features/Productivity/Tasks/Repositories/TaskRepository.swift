import Foundation

import Foundation
import Supabase
import PostgREST

// Shared creator profile struct — used by Task, Note, Event, Album, Budget, Reminder models
struct CreatorProfile: Codable, Hashable {
    let displayName: String?
    let username: String?

    var name: String { displayName ?? username ?? "Unknown" }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
    }
}

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
    var locked: Bool
    let createdAt: Date
    var updatedAt: Date
    var creator: CreatorProfile?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, creator, locked
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
            .select("*, creator:profiles!tasks_created_by_fkey(display_name, username)")
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

    func deleteTask(id: UUID) async throws {
        try await supabase
            .from("tasks")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    func setLocked(id: UUID, locked: Bool) async throws {
        struct Update: Encodable { let locked: Bool; let updated_at: String }
        try await supabase
            .from("tasks")
            .update(Update(locked: locked, updated_at: Date().iso8601))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func updateDueDate(taskId: UUID, dueAt: Date?) async throws {
        struct Update: Encodable { let due_at: String?; let updated_at: String }
        try await supabase
            .from("tasks")
            .update(Update(due_at: dueAt?.iso8601, updated_at: Date().iso8601))
            .eq("id", value: taskId.uuidString)
            .execute()
    }
}
