import SwiftUI

struct MessageInputView: View {
    @Binding var text: String
    let replyTo: DecryptedMessage?
    let onSend: () -> Void
    let onAttachment: () -> Void
    let onCancelReply: () -> Void
    let disabled: Bool
    var onTyping: (() -> Void)? = nil
    var onStopTyping: (() -> Void)? = nil

    @State private var showCommandPalette = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let reply = replyTo {
                ReplyStripView(message: reply, onDismiss: onCancelReply)
            }

            // Command palette: shown while typing the command name (before a space)
            if showCommandPalette {
                CommandPaletteView(query: paletteQuery, onSelect: { cmd in
                    text = "/\(cmd) "
                    showCommandPalette = false
                    isFocused = true
                })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Arg hint: active token highlighted, remaining dimmed — mirrors web palette row
            if let hint = activeArgHint {
                HStack(spacing: 0) {
                    Text(hint.command)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.yaplyAccent)
                    ForEach(Array(hint.tokens.enumerated()), id: \.offset) { idx, token in
                        Text(" \(token)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(
                                idx == hint.activeIndex
                                    ? Color.yaplySecondary
                                    : Color.yaplySecondary.opacity(0.35)
                            )
                            .animation(.easeInOut(duration: 0.15), value: hint.activeIndex)
                    }
                    Spacer()
                    Text(hint.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.yaplySecondary.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.yaplyTint)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onAttachment) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.yaplySecondary)
                }
                .disabled(disabled)

                HStack(alignment: .bottom) {
                    TextField("Message...", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.system(size: 15))
                        .focused($isFocused)
                        .disabled(disabled)
                        .onSubmit {
                            guard !text.isBlank else { return }
                            onSend()
                        }
                        .onChange(of: text) { _, new in
                            let isPaletteActive = new.hasPrefix("/") && !new.contains(" ")
                            withAnimation(.easeOut(duration: 0.15)) {
                                showCommandPalette = isPaletteActive
                            }
                            if !new.isEmpty { onTyping?() } else { onStopTyping?() }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yaplySurface)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.yaplyBorder))

                Button(action: {
                    guard !text.isBlank else { return }
                    onSend()
                }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(text.isBlank ? Color.yaplySecondary : Color.yaplyAccent)
                        .clipShape(Circle())
                }
                .disabled(text.isBlank || disabled)
                .animation(.easeInOut(duration: 0.15), value: text.isBlank)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.yaplySurface)
            .overlay(Rectangle().fill(Color.yaplyBorder).frame(height: 1), alignment: .top)
        }
    }

    // Query for palette filtering (text after "/" before any space)
    private var paletteQuery: String {
        guard text.hasPrefix("/") else { return "" }
        return String(text.dropFirst())
    }

    private struct ArgHint {
        let command: String
        let tokens: [String]   // individual bracket tokens e.g. ["[time]", "[message]"]
        let activeIndex: Int   // which token the cursor is currently on
        let description: String
    }

    // Shown once the user has committed a full command name + space.
    // activeIndex mirrors web: min(typed-arg-count - 1, tokens.count - 1)
    private var activeArgHint: ArgHint? {
        guard text.hasPrefix("/"), text.contains(" ") else { return nil }
        let parts = text.components(separatedBy: " ")
        let cmdName = String(parts[0].dropFirst()).lowercased()
        guard let cmd = YaplyCommand(rawValue: cmdName) else { return nil }
        let rawHint = cmd.argHint ?? ""
        let argPattern = rawHint.components(separatedBy: "  ").first ?? rawHint
        let tokens = parseBracketTokens(argPattern)
        guard !tokens.isEmpty else { return nil }
        let argsAfterCmd = Array(parts.dropFirst())
        let activeIdx = min(max(0, argsAfterCmd.count - 1), tokens.count - 1)
        return ArgHint(command: "/\(cmd.rawValue)", tokens: tokens, activeIndex: activeIdx, description: cmd.description)
    }

    // Extracts [...] groups preserving spaces inside brackets.
    // "[time] [message]" → ["[time]", "[message]"]
    // "[1h · 8h · 24h · forever]" → ["[1h · 8h · 24h · forever]"]
    private func parseBracketTokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for ch in input {
            switch ch {
            case "[":
                depth += 1
                current.append(ch)
            case "]":
                current.append(ch)
                depth -= 1
                if depth == 0 {
                    tokens.append(current)
                    current = ""
                }
            default:
                if depth > 0 { current.append(ch) }
            }
        }
        return tokens
    }

}
