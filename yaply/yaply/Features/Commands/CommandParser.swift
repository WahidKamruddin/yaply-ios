import Foundation

// Mirrors src/features/commands/commandParser.ts
struct ParsedCommand {
    let name: String       // e.g. "remind", "mute", "create"
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

// All commands available in yaply — mirrors src/features/commands/ constants
enum YaplyCommand: String, CaseIterable {
    case help       = "help"
    case remind     = "remind"
    case mute       = "mute"
    case thread     = "thread"
    case create     = "create"
    case task       = "task"
    case note       = "note"
    case album      = "album"
    case budget     = "budget"
    case plan       = "plan"

    var description: String {
        switch self {
        case .help:    return "Show available commands"
        case .remind:  return "Set a reminder — /remind [me|all|@user] [time] [message]"
        case .mute:    return "Mute this conversation — /mute [1h|8h|24h|forever]"
        case .thread:  return "Create a thread — /thread [name]"
        case .create:  return "Create an item — /create [task|note|album|budget|poll|event]"
        case .task:    return "Create a task — /task [title]"
        case .note:    return "Create a note — /note [title]"
        case .album:   return "Create an album — /album [title]"
        case .budget:  return "Create a budget — /budget [title]"
        case .plan:    return "Create a shared plan — /plan [title]"
        }
    }

    static func matching(prefix: String) -> [YaplyCommand] {
        let q = prefix.lowercased()
        guard !q.isEmpty else { return allCases }
        return allCases.filter { $0.rawValue.hasPrefix(q) }
    }
}
