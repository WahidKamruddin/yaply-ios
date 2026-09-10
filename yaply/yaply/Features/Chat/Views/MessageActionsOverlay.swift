import SwiftUI

/// The Messenger / Instagram–style long-press menu: a horizontal reaction rail
/// on top (6 personalized emoji + a "+" to swap one), a copy of the tapped
/// bubble in the middle, and an action card below (Reply · Copy · More, where
/// More reveals Pin / Delete / back).
struct MessageActionsOverlay: View {
    let message: DecryptedMessage
    let isOwn: Bool
    let myReaction: String?
    let isPinned: Bool
    let canDelete: Bool
    /// Global-space vertical center of the bubble that was long-pressed.
    let anchorY: CGFloat

    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @State private var reactions = CustomReactionStore.shared
    @State private var showEmojiPicker = false
    @State private var inMoreMenu = false
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(appeared ? 1 : 0)
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(appeared ? 0.18 : 0).ignoresSafeArea())
                    .onTapGesture { dismiss() }

                VStack(alignment: isOwn ? .trailing : .leading, spacing: 10) {
                    reactionRail
                    BubbleContentView(message: message, isOwn: isOwn)
                        .allowsHitTesting(false)
                    actionCard
                }
                .frame(maxWidth: geo.size.width - 48, alignment: isOwn ? .trailing : .leading)
                .padding(.horizontal, 24)
                .offset(y: contentY(in: geo.size.height))
                .scaleEffect(appeared ? 1 : 0.9, anchor: isOwn ? .topTrailing : .topLeading)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { appeared = true }
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet { emoji in
                reactions.promote(emoji)
                onReact(emoji)
                dismiss()
            }
        }
    }

    private func contentY(in height: CGFloat) -> CGFloat {
        // Keep the rail+bubble+card group on screen, roughly anchored to the bubble.
        min(max(anchorY - 96, 72), height - 300)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onDismiss() }
    }

    // MARK: - Reaction rail

    private var reactionRail: some View {
        HStack(spacing: 4) {
            ForEach(Array(reactions.emojis.enumerated()), id: \.offset) { _, emoji in
                Button {
                    onReact(emoji)
                    dismiss()
                } label: {
                    Text(emoji)
                        .font(.system(size: 28))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(myReaction == emoji ? Color.yaplyAccent.opacity(0.22) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Button { showEmojiPicker = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.yaplyBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .shadow(color: Color.yaplyShadow, radius: 10, y: 4)
    }

    // MARK: - Action card

    private var actionCard: some View {
        VStack(spacing: 0) {
            if inMoreMenu {
                actionRow(isPinned ? "Unpin" : "Pin", icon: isPinned ? "pin.slash" : "pin") {
                    onTogglePin(); dismiss()
                }
                if canDelete {
                    divider
                    actionRow("Delete", icon: "trash", destructive: true) {
                        onDelete(); dismiss()
                    }
                }
                divider
                actionRow("More", icon: "chevron.backward") {
                    withAnimation(.easeInOut(duration: 0.15)) { inMoreMenu = false }
                }
            } else {
                actionRow("Reply", icon: "arrowshape.turn.up.left") { onReply(); dismiss() }
                divider
                actionRow("Copy", icon: "doc.on.doc") { onCopy(); dismiss() }
                divider
                actionRow("More", icon: "ellipsis") {
                    withAnimation(.easeInOut(duration: 0.15)) { inMoreMenu = true }
                }
            }
        }
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .shadow(color: Color.yaplyShadow, radius: 12, y: 5)
    }

    private var divider: some View {
        Rectangle().fill(Color.yaplyBorderSoft.opacity(0.6)).frame(height: 0.5)
    }

    private func actionRow(_ title: String, icon: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16))
                Spacer()
                Image(systemName: icon).font(.system(size: 15))
            }
            .foregroundStyle(destructive ? Color.yaplyDanger : Color.yaplyPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
