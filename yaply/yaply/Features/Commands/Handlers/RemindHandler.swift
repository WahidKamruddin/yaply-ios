import Foundation
import UserNotifications
import Supabase
import PostgREST

// Mirrors src/features/commands/handlers/remindHandler.ts
// /remind [time] [message]  e.g. /remind 30m Pick up groceries
// Reminders are now shared — all conversation members can view.
enum RemindHandler {

    static func execute(args: [String], conversationId: UUID, userId: UUID) async throws {
        guard !args.isEmpty else { return }

        var remaining = args
        let timeArg = remaining.removeFirst()
        let message = remaining.joined(separator: " ")

        let fireDate = parseTime(timeArg) ?? Date().addingTimeInterval(3600)

        struct ReminderInsert: Encodable {
            let conversation_id: String
            let user_id: String
            let message: String
            let remind_at: String
        }

        let insert = ReminderInsert(
            conversation_id: conversationId.uuidString,
            user_id: userId.uuidString,
            message: message.isEmpty ? "Reminder" : message,
            remind_at: fireDate.iso8601
        )

        try await supabase.from("reminders").insert(insert).execute()

        await scheduleLocalNotification(message: message.isEmpty ? "Reminder" : message, at: fireDate)
    }

    static func parseTime(_ arg: String) -> Date? {
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
