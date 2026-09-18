import Foundation
import Supabase
import PostgREST

// Mirrors src/features/commands/handlers/remindHandler.ts
// Format: /remind [date] [time] [message]
//   Date: today · tomorrow · MM/DD/YYYY
//   Time: 9pm · 10am · 9:30pm · 14:30 · 9:00
// Example: /remind today 3:00pm Call Alice
enum RemindHandler {

    enum RemindError: LocalizedError {
        case tooFewArgs
        case badDateTime
        case emptyMessage

        var errorDescription: String? {
            switch self {
            case .tooFewArgs:
                return "Usage: /remind [date] [time] [message]\nDate: today · tomorrow · MM/DD/YYYY\nTime: 3pm · 14:30 · 9:30am\nExample: /remind today 3:00pm Call Alice"
            case .badDateTime:
                return "Couldn't parse date/time. Try: today 3pm · tomorrow 9am · 06/15/2026 3:00pm"
            case .emptyMessage:
                return "Please include a reminder message after the date and time."
            }
        }
    }

    // Throws RemindError on failure. Success is announced to the whole chat by
    // the item-created pill, not local feedback (mirrors web remindHandler.ts).
    static func execute(args: [String], conversationId: UUID, userId: UUID) async throws {
        guard args.count >= 3 else { throw RemindError.tooFewArgs }

        let dateStr = args[0]
        let timeStr = args[1]
        let message = args.dropFirst(2).joined(separator: " ")

        guard !message.isEmpty else { throw RemindError.emptyMessage }
        guard let fireDate = parseDateTimeArgs(dateStr: dateStr, timeStr: timeStr) else {
            throw RemindError.badDateTime
        }

        // Delivery is the server's job: migration 00042's pg_cron job pushes at
        // remind_at. Scheduling locally as well fired the reminder twice, and the
        // local copy only ever reached the device that typed the command and was
        // lost on reinstall.
        try await ReminderRepository().createReminder(conversationId: conversationId, userId: userId, message: message, remindAt: fireDate)
    }

    // MARK: - Date + time parsing  mirrors parseDateTimeArgs in commandParser.ts

    // dateStr: "today" | "tomorrow" | "MM/DD/YYYY"
    // timeStr: "9pm" | "10am" | "9:30pm" | "14:30" | "9:00"
    static func parseDateTimeArgs(dateStr: String, timeStr: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)

        switch dateStr.lowercased().trimmingCharacters(in: .whitespaces) {
        case "today":
            break
        case "tomorrow":
            comps.day = (comps.day ?? 0) + 1
        default:
            let parts = dateStr.split(separator: "/")
            guard parts.count == 3,
                  let m = Int(parts[0]), m >= 1, m <= 12,
                  let d = Int(parts[1]), d >= 1, d <= 31,
                  let y = Int(parts[2]) else { return nil }
            comps.month = m
            comps.day   = d
            comps.year  = y
        }

        guard let (hour, minute) = parseTime(timeStr) else { return nil }
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0

        return cal.date(from: comps)
    }

    // Accepts: 9pm, 10am, 9:30pm, 14:30, 9:00
    private static func parseTime(_ str: String) -> (Int, Int)? {
        let lower = str.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{1,2})(?::(\d{2}))?(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
        else { return nil }

        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: lower) else { return nil }
            return String(lower[range])
        }

        guard let hStr = group(1), var hour = Int(hStr) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        let ampm   = group(3)

        if ampm == "pm" && hour < 12 { hour += 12 }
        if ampm == "am" && hour == 12 { hour = 0 }
        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { return nil }

        return (hour, minute)
    }
}
