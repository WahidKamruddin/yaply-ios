import Foundation

// Mirrors src/features/commands/handlers/muteHandler.ts
enum MuteHandler {
    enum Duration {
        case oneHour, eightHours, oneDay, forever, unmute

        var date: Date? {
            switch self {
            case .oneHour:    return Date().addingTimeInterval(3600)
            case .eightHours: return Date().addingTimeInterval(28800)
            case .oneDay:     return Date().addingTimeInterval(86400)
            case .forever:    return Date.distantFuture
            case .unmute:     return nil
            }
        }

        init?(_ arg: String) {
            switch arg.lowercased() {
            case "1h":      self = .oneHour
            case "8h":      self = .eightHours
            case "24h", "1d": self = .oneDay
            case "forever": self = .forever
            case "off", "unmute": self = .unmute
            default:        return nil
            }
        }
    }

    static func execute(
        args: [String],
        conversationId: UUID,
        userId: UUID
    ) async throws {
        let duration = args.first.flatMap(Duration.init) ?? .oneHour
        let repo = ConversationRepository()
        try await repo.muteConversation(conversationId: conversationId, userId: userId, until: duration.date)
    }
}
