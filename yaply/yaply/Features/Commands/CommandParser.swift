import Foundation

// Mirrors src/features/commands/commandParser.ts
struct ParsedCommand {
    let name: String       // e.g. "remind", "mute"
    let rawArgs: String    // everything after the command name
    let args: [String]     // whitespace-split args

    static func parse(_ input: String) -> ParsedCommand? {
        guard input.hasPrefix("/") else { return nil }
        let trimmed = String(input.dropFirst()).trimmingCharacters(in: .whitespaces)
        var parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first else { return nil }
        parts.removeFirst()
        return ParsedCommand(name: name.lowercased(), rawArgs: parts.joined(separator: " "), args: parts)
    }
}

enum YaplyCommand: String, CaseIterable {
    case help    = "help"
    case remind  = "remind"
    case mute    = "mute"
    case thread  = "thread"
    case task    = "task"
    case note    = "note"
    case album   = "album"
    case budget  = "budget"
    case plan    = "plan"
    case event   = "event"

    var description: String {
        switch self {
        case .help:   return "Show available commands"
        case .remind: return "Set a reminder"
        case .mute:   return "Mute this conversation"
        case .thread: return "Reply in a thread"
        case .task:   return "Create a task"
        case .note:   return "Create a note"
        case .album:  return "Create a photo album"
        case .budget: return "Create a budget"
        case .plan:   return "Schedule availability (when2meet)"
        case .event:  return "Create a confirmed event"
        }
    }

    // Arg hint shown in the input field after command name + space
    var argHint: String? {
        switch self {
        case .remind: return "[time] [message]  e.g. 30m Groceries"
        case .mute:   return "[1h · 8h · 24h · forever]"
        case .task:   return "[title]"
        case .note:   return "[title]"
        case .album:  return "[name]"
        case .budget: return "[name]"
        case .plan:   return "[name]"
        case .event:  return "[name]"
        case .thread: return "[name]"
        case .help:   return nil
        }
    }

    static func matching(prefix: String) -> [YaplyCommand] {
        let q = prefix.lowercased()
        guard !q.isEmpty else { return allCases }
        return allCases.filter { $0.rawValue.hasPrefix(q) }
    }
}
