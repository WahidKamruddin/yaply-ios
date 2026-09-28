import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Supabase

struct MessageInputView: View {
    @Binding var text: String
    let replyTo: DecryptedMessage?
    // The resolved (and not dismissed) link preview at the moment of send, if
    // any — sealed alongside the text by the caller. See ../CLAUDE.md's "Link
    // previews" section.
    // `latePreview` is handed along when a fetch is still in flight — the
    // message must never wait on it (send now, attach later if/when it
    // resolves). See ../CLAUDE.md's "Link previews" section.
    let onSend: (LinkPreview?, Task<LinkPreview?, Never>?) -> Void
    let onCancelReply: () -> Void
    let disabled: Bool
    /// Expanding attachment menu actions (Messenger / Instagram style).
    /// Default to no-ops so lightweight hosts (e.g. ThreadView) can omit them.
    var onPickFile: () -> Void = {}
    var onPickCamera: () -> Void = {}
    var onPickImage: () -> Void = {}
    var onStartVoice: () -> Void = {}
    /// Emoji / expression button that lives inside the text field.
    var onEmoji: () -> Void = {}
    /// Hides the attachment menu + emoji button entirely (thread replies).
    var showAttachments: Bool = true
    var onTyping: (() -> Void)? = nil
    var onStopTyping: (() -> Void)? = nil
    /// A sticker/image pasted from the clipboard (e.g. a sticker copied in Messages).
    var onPasteImage: ((UIImage) -> Void)? = nil
    /// Fires when the text field gains/loses focus, so the host can keep the
    /// bottom of the message list visible as the keyboard opens/closes.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// @mentions only exist in group chats — both default to disabled so DM/
    /// thread hosts that don't pass them get plain composer behavior.
    var members: [MemberSummary] = []
    var isGroup: Bool = false

    @State private var showCommandPalette = false
    @State private var canPasteImage = false
    @State private var menuExpanded = false
    @State private var mentionDismissedForQuery: String? = nil
    @FocusState private var isFocused: Bool

    // Link preview — debounced-resolve-then-seal, mirroring the web composer
    // (MessageInput.tsx). See ../CLAUDE.md's "Link previews" section.
    @State private var linkPreview: LinkPreview?
    @State private var previewLoading = false
    @State private var previewDismissed = false
    @State private var lastResolvedUrl: String?
    // The in-flight fetch, if any — captured at send time and handed along
    // instead of cancelled, so a still-resolving preview can be attached
    // after the message already sent.
    @State private var previewTask: Task<LinkPreview?, Never>?

    private var activePreview: LinkPreview? { previewDismissed ? nil : linkPreview }

    private func handleLinkPreviewChange(_ newText: String) {
        guard let url = LinkPreviewCodec.extractFirstUrl(newText) else {
            previewTask?.cancel()
            lastResolvedUrl = nil
            linkPreview = nil
            previewLoading = false
            previewDismissed = false
            previewTask = nil
            return
        }
        guard url != lastResolvedUrl else { return }
        lastResolvedUrl = url
        previewDismissed = false
        previewLoading = true
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return nil }
            struct RequestBody: Encodable { let url: String }
            var result: LinkPreview?
            do {
                result = try await supabase.functions.invoke(
                    "link-preview", options: .init(body: RequestBody(url: url))
                )
            } catch {
                result = nil
            }
            if !Task.isCancelled {
                linkPreview = result
                previewLoading = false
            }
            return result
        }
    }

    // Resets composer state only — never cancels a task already handed to
    // `onSend` as `latePreview`, which keeps resolving independently.
    private func resetLinkPreview() {
        linkPreview = nil
        previewLoading = false
        previewDismissed = false
        lastResolvedUrl = nil
        previewTask = nil
    }

    // Never blocks sending on the fetch: seals in whatever's already
    // resolved; if one's still in flight, hands its Task along instead of
    // cancelling it.
    private func performSend() {
        let resolvedPreview = activePreview
        let latePreview = (resolvedPreview == nil && previewLoading) ? previewTask : nil
        resetLinkPreview()
        onSend(resolvedPreview, latePreview)
    }

    // SwiftUI's TextField exposes no caret position, so — unlike the web
    // composer, which tracks the real caret — this treats the trailing
    // @-token as active. Equivalent in practice since typing only appends.
    private var mentionQuery: (query: String, start: String.Index, end: String.Index)? {
        guard isGroup, !text.hasPrefix("/") else { return nil }
        return Mentions.activeMentionQuery(text: text, caretIndex: text.endIndex)
    }

    private var mentionCandidates: [MentionOption] {
        guard let mentionQuery else { return [] }
        let query = mentionQuery.query
        var options: [MentionOption] = []
        if Mentions.everyone.hasPrefix(query) {
            options.append(MentionOption(id: "everyone", everyone: true, userId: nil, username: Mentions.everyone, displayName: "Notify everyone", avatarUrl: nil))
        }
        for m in members {
            let uname = m.profile.username.lowercased()
            let dname = (m.profile.displayName ?? "").lowercased()
            guard uname.hasPrefix(query) || dname.hasPrefix(query) else { continue }
            options.append(MentionOption(id: m.userId.uuidString, everyone: false, userId: m.userId, username: m.profile.username, displayName: m.profile.name, avatarUrl: m.profile.avatarUrl))
            if options.count >= 8 { break }
        }
        return options
    }

    // Escape-equivalent: tapping outside doesn't exist here since there's no
    // keyboard nav, but this still lets a caller dismiss the palette for the
    // in-progress token without it reappearing until a new one starts.
    private var showMentionPalette: Bool {
        guard let mentionQuery else { return false }
        return !mentionCandidates.isEmpty && mentionDismissedForQuery != mentionQuery.query
    }

    private func selectMention(_ option: MentionOption) {
        guard let mentionQuery else { return }
        let insert = "@\(option.username) "
        text = text.replacingCharacters(in: mentionQuery.start..<mentionQuery.end, with: insert)
        mentionDismissedForQuery = nil
    }

    /// Text-field container shape: a true capsule for iMessage, a rounded
    /// rect (Messenger's is a touch tighter than yaply's default) otherwise.
    private var textFieldShape: AnyShape {
        switch ChatStyle.current {
        case .imessage: return AnyShape(Capsule())
        case .messenger: return AnyShape(RoundedRectangle(cornerRadius: 20))
        case .yaply: return AnyShape(RoundedRectangle(cornerRadius: 22))
        }
    }

    /// Composer bar background: flat surface color for yaply/Messenger,
    /// translucent blur for iMessage, matching its composer chrome.
    private var composerBarBackground: AnyShapeStyle {
        ChatStyle.current == .imessage
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(Color.yaplySurface)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reply = replyTo {
                ReplyStripView(message: reply, onDismiss: onCancelReply)
            }

            if previewLoading || activePreview != nil {
                LinkPreviewChipView(
                    preview: activePreview,
                    isLoading: previewLoading,
                    onDismiss: { previewDismissed = true }
                )
            }

            // Command palette: shown while typing the command name (before a space)
            if showCommandPalette {
                CommandPaletteView(query: paletteQuery, onSelect: { cmd in
                    text = "/\(cmd) "
                    showCommandPalette = false
                    isFocused = true
                })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showMentionPalette {
                MentionPaletteView(
                    options: mentionCandidates,
                    onSelect: { option in
                        selectMention(option)
                        isFocused = true
                    },
                    onDismiss: { mentionDismissedForQuery = mentionQuery?.query }
                )
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

            HStack(alignment: .bottom, spacing: 8) {
                if showAttachments {
                    // Leading toggle: collapsed shows a "+", expanded shows a chevron
                    // that closes the menu again. Same model as Messenger / Instagram.
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            menuExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: menuExpanded ? "chevron.right" : "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.yaplySecondary)
                            .frame(width: 30, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(YaplyPressStyle())
                    .accessibilityLabel(menuExpanded ? "Hide attachment options" : "Show attachment options")
                    .disabled(disabled)
                }

                // Expanding action row. The text field naturally narrows to make room.
                if showAttachments, menuExpanded {
                    HStack(spacing: 6) {
                        attachmentButton("doc", action: onPickFile)
                        attachmentButton("camera", action: onPickCamera)
                        attachmentButton("mic", action: onStartVoice)
                        attachmentButton("photo", action: onPickImage)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                if !menuExpanded, canPasteImage, let onPasteImage {
                    PasteButton(supportedContentTypes: [.image]) { providers in
                        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else { return }
                        _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                            guard let image = object as? UIImage else { return }
                            DispatchQueue.main.async { onPasteImage(image) }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Color.yaplyAccent)
                    .disabled(disabled)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message...", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.system(size: 15))
                        .focused($isFocused)
                        .disabled(disabled)
                        .onSubmit {
                            guard !text.isBlank else { return }
                            performSend()
                        }
                        .onChange(of: text) { _, new in
                            let isPaletteActive = new.hasPrefix("/") && !new.contains(" ")
                            withAnimation(.easeOut(duration: 0.15)) {
                                showCommandPalette = isPaletteActive
                            }
                            if !new.isEmpty {
                                onTyping?()
                                if menuExpanded {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        menuExpanded = false
                                    }
                                }
                            } else {
                                onStopTyping?()
                            }
                            handleLinkPreviewChange(new)
                        }

                    if showAttachments {
                        Button(action: onEmoji) {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                        .buttonStyle(YaplyPressStyle())
                        .accessibilityLabel("Emoji and GIFs")
                        .disabled(disabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yaplySurface)
                .clipShape(textFieldShape)
                .overlay(
                    textFieldShape
                        .stroke(isFocused ? Color.yaplyAccent.opacity(0.5) : Color.yaplyBorder,
                                lineWidth: isFocused ? 1.5 : 1)
                )
                .yaplyAnimation(.easeOut(duration: 0.15), value: isFocused)

                Button(action: {
                    guard !text.isBlank else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    performSend()
                }) {
                    Image(systemName: ChatStyle.current == .imessage ? "arrow.up" : "message.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(text.isBlank ? Color.yaplySecondary : Color.yaplyAccent)
                        .clipShape(Circle())
                        .frame(height: 38, alignment: .center)
                }
                .buttonStyle(YaplyPressStyle())
                .accessibilityLabel("Send message")
                .disabled(text.isBlank || disabled)
                .yaplyAnimation(.easeInOut(duration: 0.15), value: text.isBlank)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(composerBarBackground)
            .overlay(
                Rectangle()
                    .fill(Color.yaplyBorder.opacity(ChatStyle.current == .imessage ? 0.5 : 1))
                    .frame(height: 1),
                alignment: .top
            )
        }
        .onChange(of: isFocused) { _, focused in
            if focused, menuExpanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    menuExpanded = false
                }
            }
            onFocusChange(focused)
        }
        .onAppear { canPasteImage = UIPasteboard.general.hasImages }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            canPasteImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            canPasteImage = UIPasteboard.general.hasImages
        }
    }

    private func attachmentButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                menuExpanded = false
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.yaplyAccent)
                .frame(width: 34, height: 34)
                .background(Color.yaplyTint)
                .clipShape(Circle())
        }
        .disabled(disabled)
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
