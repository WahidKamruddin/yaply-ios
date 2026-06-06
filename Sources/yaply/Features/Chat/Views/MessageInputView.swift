import SwiftUI

struct MessageInputView: View {
    @Binding var text: String
    let replyTo: DecryptedMessage?
    let onSend: () -> Void
    let onAttachment: () -> Void
    let onCancelReply: () -> Void
    let disabled: Bool

    @State private var showCommandPalette = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let reply = replyTo {
                ReplyStripView(message: reply, onDismiss: onCancelReply)
            }

            if showCommandPalette {
                CommandPaletteView(query: commandQuery, onSelect: { cmd in
                    text = "/\(cmd) "
                    showCommandPalette = false
                    isFocused = true
                })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Attachment button
                Button(action: onAttachment) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.yaplySecondary)
                }
                .disabled(disabled)

                // Text input
                HStack(alignment: .bottom) {
                    TextField("Message...", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.system(size: 15))
                        .focused($isFocused)
                        .disabled(disabled)
                        .onChange(of: text) { _, new in
                            withAnimation(.easeOut(duration: 0.15)) {
                                showCommandPalette = new.hasPrefix("/") && !new.contains(" ")
                            }
                        }

                    // GIF button
                    Button(action: onAttachment) {
                        Text("GIF")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.yaplySecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.yaplyBorder))
                    }
                    .disabled(disabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.yaplyBorder))

                // Send button
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
            .background(Color.white)
            .overlay(Rectangle().fill(Color.yaplyBorder).frame(height: 1), alignment: .top)
        }
    }

    private var commandQuery: String {
        guard text.hasPrefix("/") else { return "" }
        return String(text.dropFirst())
    }
}
