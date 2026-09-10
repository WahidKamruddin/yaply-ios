import SwiftUI

/// The Messenger / Instagram–style long-press menu. The tapped bubble stays
/// exactly where it was on screen (a pixel-aligned copy over a dimmed backdrop);
/// the reaction rail floats just above it and the action card just below. The
/// whole group only shifts vertically if the rail or card would fall off screen.
struct MessageActionsOverlay: View {
    let message: DecryptedMessage
    let isOwn: Bool
    let myReaction: String?
    let isPinned: Bool
    let canDelete: Bool
    /// Global-space frame of the bubble that was long-pressed.
    let anchorRect: CGRect

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
    @State private var railSize: CGSize = CGSize(width: 300, height: 52)
    @State private var cardSize: CGSize = CGSize(width: 250, height: 140)

    private let railGap: CGFloat = 10
    private let cardGap: CGFloat = 10
    private let topMargin: CGFloat = 64
    private let bottomMargin: CGFloat = 44
    private let sideMargin: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let dy = verticalShift(in: geo.size)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.18))
                    .opacity(appeared ? 1 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                // The bubble — held in place (only moves with the shared dy).
                BubbleContentView(message: message, isOwn: isOwn)
                    .frame(width: anchorRect.width, alignment: isOwn ? .trailing : .leading)
                    .position(x: anchorRect.midX, y: anchorRect.midY + dy)
                    .allowsHitTesting(false)
                    .opacity(appeared ? 1 : 0)

                reactionRail
                    .measure { railSize = $0 }
                    .scaleEffect(appeared ? 1 : 0.85, anchor: .bottom)
                    .opacity(appeared ? 1 : 0)
                    .position(
                        x: clampedX(sideAlignedCenter(width: railSize.width), width: railSize.width, in: geo.size.width),
                        y: anchorRect.minY + dy - railGap - railSize.height / 2
                    )

                actionCard
                    .measure { cardSize = $0 }
                    .scaleEffect(appeared ? 1 : 0.85, anchor: .top)
                    .opacity(appeared ? 1 : 0)
                    .position(
                        x: clampedX(sideAlignedCenter(width: cardSize.width), width: cardSize.width, in: geo.size.width),
                        y: anchorRect.maxY + dy + cardGap + cardSize.height / 2
                    )
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet { emoji in
                reactions.promote(emoji)
                onReact(emoji)
                dismiss()
            }
        }
    }

    // MARK: - Positioning

    /// Center x so the rail/card hugs the same edge as the bubble.
    private func sideAlignedCenter(width: CGFloat) -> CGFloat {
        isOwn ? anchorRect.maxX - width / 2 : anchorRect.minX + width / 2
    }

    private func clampedX(_ center: CGFloat, width: CGFloat, in totalWidth: CGFloat) -> CGFloat {
        let half = width / 2
        return min(max(center, sideMargin + half), totalWidth - sideMargin - half)
    }

    /// How far to slide the whole group so the rail (above) and card (below) stay
    /// on screen. Prefers to keep the card fully visible.
    private func verticalShift(in size: CGSize) -> CGFloat {
        let railTop = anchorRect.minY - railGap - railSize.height
        let cardBottom = anchorRect.maxY + cardGap + cardSize.height
        let overflowTop = topMargin - railTop
        let overflowBottom = cardBottom - (size.height - bottomMargin)
        if overflowBottom > 0 { return -overflowBottom }
        if overflowTop > 0 { return overflowTop }
        return 0
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
                        .font(.system(size: 27))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(myReaction == emoji ? Color.yaplyAccent.opacity(0.22) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Button { showEmojiPicker = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(width: 36, height: 36)
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

private extension View {
    /// Reports this view's rendered size once and on change.
    func measure(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onChange(proxy.size) }
                    .onChange(of: proxy.size) { _, new in onChange(new) }
            }
        )
    }
}
