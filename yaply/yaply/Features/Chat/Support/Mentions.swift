import Foundation

// @mentions — group chats only. This must match the web grammar in
// packages/shared/src/mentions.ts byte-for-byte (../CLAUDE.md's mentions
// section) or the two platforms disagree on what counts as a mention.
enum Mentions {
    static let everyone = "everyone"

    // Same charset as usernameSchema (web validators.ts): a-z 0-9 _ . -
    private static func isMentionChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-")
    }

    struct Candidate {
        let userId: UUID
        let username: String
    }

    enum Token {
        case text(String)
        case mention(value: String, userId: UUID?, everyone: Bool)
    }

    /// The `@`-token, if any, that the caret sits inside or right after.
    /// Triggers only at start-of-text or after whitespace, so an email never
    /// opens the palette.
    static func activeMentionQuery(text: String, caretIndex: String.Index) -> (query: String, start: String.Index, end: String.Index)? {
        let upToCaret = text[text.startIndex..<caretIndex]
        guard let atIndex = upToCaret.lastIndex(of: "@") else { return nil }
        if atIndex > text.startIndex {
            let before = text.index(before: atIndex)
            if !text[before].isWhitespace { return nil }
        }
        let rest = text[text.index(after: atIndex)..<caretIndex]
        guard rest.allSatisfy(isMentionChar) else { return nil }

        var end = caretIndex
        while end < text.endIndex, isMentionChar(text[end]) {
            end = text.index(after: end)
        }
        return (String(rest).lowercased(), atIndex, end)
    }

    private static func resolve(_ candidate: Substring, members: [Candidate]) -> (userId: UUID?, everyone: Bool, matchedLength: Int)? {
        let lower = candidate.lowercased()

        if lower.hasPrefix(everyone) {
            return (nil, true, everyone.count)
        }

        var best: (userId: UUID, length: Int)?
        for m in members {
            let uname = m.username.lowercased()
            if lower.hasPrefix(uname), (best == nil || uname.count > best!.length) {
                best = (m.userId, uname.count)
            }
        }
        guard let best else { return nil }
        return (best.userId, false, best.length)
    }

    /// Extract mention targeting from composed plaintext, before encryption.
    static func extractMentions(text: String, members: [Candidate], senderId: UUID) -> (mentionedUserIds: [UUID], mentionsEveryone: Bool) {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        var isEveryone = false

        forEachMentionMatch(in: text) { candidate, _, _ in
            guard let resolved = resolve(candidate, members: members) else { return }
            if resolved.everyone {
                isEveryone = true
            } else if let uid = resolved.userId, uid != senderId, !seen.contains(uid) {
                seen.insert(uid)
                ids.append(uid)
            }
        }

        return (ids, isEveryone)
    }

    /// Split decrypted text into plain/mention runs for rendering.
    static func tokenizeMentions(text: String, members: [Candidate]) -> [Token] {
        var tokens: [Token] = []
        var lastIndex = text.startIndex

        forEachMentionMatch(in: text) { candidate, leadingStart, atIndex in
            guard let resolved = resolve(candidate, members: members) else { return }
            let matchedText = "@" + candidate.prefix(resolved.matchedLength)
            let mentionEnd = text.index(atIndex, offsetBy: matchedText.count)

            if atIndex > lastIndex {
                tokens.append(.text(String(text[lastIndex..<atIndex])))
            }
            tokens.append(.mention(value: matchedText, userId: resolved.everyone ? nil : resolved.userId, everyone: resolved.everyone))
            lastIndex = mentionEnd
        }

        if lastIndex < text.endIndex {
            tokens.append(.text(String(text[lastIndex...])))
        }
        if tokens.isEmpty {
            tokens.append(.text(text))
        }
        return tokens
    }

    // Walks `@`-tokens that trigger at start-of-text or after whitespace,
    // calling `body(candidate, leadingStart, atIndex)` for each with the
    // candidate substring (letters/digits/_/./- run after the `@`).
    private static func forEachMentionMatch(in text: String, _ body: (Substring, String.Index, String.Index) -> Void) {
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "@", i == text.startIndex || text[text.index(before: i)].isWhitespace else {
                i = text.index(after: i)
                continue
            }
            let atIndex = i
            let candidateStart = text.index(after: i)
            var j = candidateStart
            while j < text.endIndex, isMentionChar(text[j]) {
                j = text.index(after: j)
            }
            if j > candidateStart {
                body(text[candidateStart..<j], atIndex, atIndex)
            }
            i = j > i ? j : text.index(after: i)
        }
    }
}
