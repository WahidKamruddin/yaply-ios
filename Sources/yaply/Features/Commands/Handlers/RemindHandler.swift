import Foundation
import UserNotifications

// Mirrors src/features/commands/handlers/remindHandler.ts
// /remind [me|all|@user] [time] [message]  e.g. /remind me 30m Pick up groceries
enum RemindHandler {

    static func execute(args: [String], conversationId: UUID, userId: UUID) async throws {
        guard !args.isEmpty else { return }

        var remaining = args
        let targetArg = remaining.removeFirst()      // "me", "all", or "@username"
        let timeArg = remaining.isEmpty ? "1h" : remaining.removeFirst()
        let message = remaining.joined(separator: " ")

        let fireDate = parseTime(timeArg) ?? Date().addingTimeInterval(3600)

        // Insert into reminders table
        struct ReminderInsert: Encodable {
            let conversation_id: String
            let created_by: String
            let message: String
            let remind_at: String
            let target_type: String
        }

        let targetType = targetArg == "all" ? "all" : targetArg.hasPrefix("@") ? "user" : "me"
        let insert = ReminderInsert(
            conversation_id: conversationId.uuidString,
            created_by: userId.uuidString,
            message: message.isEmpty ? "Reminder" : message,
            remind_at: fireDate.iso8601,
            target_type: targetType
        )

        try await supabase.from("reminders").insert(insert).execute()

        // Schedule local notification for "me" reminders
        if targetType == "me" {
            await scheduleLocalNotification(message: message.isEmpty ? "Reminder" : message, at: fireDate)
        }
    }

    private static func parseTime(_ arg: String) -> Date? {
        let lower = arg.lowercased()
        let num = Double(lower.dropLast()) ?? 1
        if lower.hasSuffix("m") { return Date().addingTimeInterval(num * 60) }
        if lower.hasSuffix("h") { return Date().addingTimeInterval(num * 3600) }
        if lower.hasSuffix("d") { return Date().addingTimeInterval(num * 86400) }
        return nil
    }

    private static func scheduleLocalNotification(message: String, at date: Date) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "yaply Reminder"
        content.body = message
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await center.add(request)
    }
}
