import SwiftUI

/// Send animation: the composer's text box *becomes* the new bubble. The
/// field's chrome detaches, morphs into the bubble's shape and colour, and flies
/// into the list carrying the text. Mirrors web's `features/chat/lib/sendFlight.ts`,
/// and both follow Telegram-iOS, the open-source client with the same effect
/// (`ChatMessageTransitionNode` + `animateContentFromTextInputField`):
/// - 300ms
/// - X and Y on separate curves, so the path bows instead of running straight
/// - the background animates from the input field's frame to the bubble's
/// - the real bubble stays hidden until the flight lands
///
/// The text is drawn at the bubble's final width the whole way, so it never
/// reflows. The real row is hidden (`SendFlightHidden`) while `rowId` matches,
/// which is why rows are keyed by `DecryptedMessage.rowId`: the temp → real id
/// swap on confirm can land mid-flight and must not reveal or remount the row.
struct SendFlight {
    let rowId: UUID
    let message: DecryptedMessage
    /// Global frame of the composer's TextField at the moment of send.
    let fieldFrame: CGRect
    /// Global frame of the field's chrome (the rounded box around it).
    let chromeFrame: CGRect
    let chromeRadius: CGFloat
    /// The bubble's global frame once it's laid out; nil until measured.
    var target: CGRect?
    var position: BubblePosition = .single
    var landedX = false
    var landedY = false
    var filled = false

    /// BubbleContentView's text inset — the ghost lines its text up with the
    /// field's by offsetting the bubble by this much.
    static let textInset = CGSize(width: 14, height: 10)

    static let duration: TimeInterval = 0.3
    /// Telegram's curves: horizontal is fast-out, vertical eases in and out.
    static let curveX = Animation.timingCurve(0.23, 1, 0.32, 1, duration: duration)
    static let curveY = Animation.timingCurve(0.199, 0.011, 0.279, 0.910, duration: duration)
    static let fade = Animation.easeOut(duration: duration * 0.55)
}

/// Holds the in-progress flight outside ChatView's own state. Only the overlay
/// and the one hidden row read it, so each step of a flight (start, measure,
/// land, finish) redraws those — never ChatView's whole body and message list.
@Observable
final class SendFlightStore {
    var flight: SendFlight?
}

/// The overlay layer; reads the store in its own body.
struct SendFlightLayer: View {
    let store: SendFlightStore
    var mentionMembers: [MemberSummary] = []
    var currentUserId: UUID?

    var body: some View {
        if let flight = store.flight {
            SendFlightOverlay(flight: flight, mentionMembers: mentionMembers, currentUserId: currentUserId)
        }
    }
}

/// Hides the real row while its ghost is in the air.
struct SendFlightHidden: ViewModifier {
    let store: SendFlightStore
    let rowId: UUID

    func body(content: Content) -> some View {
        content.opacity(store.flight?.rowId == rowId ? 0 : 1)
    }
}

struct SendFlightOverlay: View {
    let flight: SendFlight
    var mentionMembers: [MemberSummary] = []
    var currentUserId: UUID?

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let inset = SendFlight.textInset
            // Where the bubble box sits so its text lines up with the field's.
            let start = CGPoint(x: flight.fieldFrame.minX - inset.width, y: flight.fieldFrame.minY - inset.height)
            let size = flight.target?.size ?? CGSize(
                width: flight.fieldFrame.width + inset.width * 2,
                height: flight.fieldFrame.height + inset.height * 2
            )
            let end = flight.target?.origin ?? start
            // The morphing box, in the ghost's own coordinates: the field's
            // chrome at the start, the whole bubble at the end. Width and x
            // follow the X curve, height and y the Y curve (separate values,
            // so each interpolates in its own transaction).
            let chrome = flight.chromeFrame.offsetBy(dx: -start.x, dy: -start.y)
            let boxX = flight.landedX ? 0 : chrome.minX
            let boxW = flight.landedX ? size.width : chrome.width
            let boxY = flight.landedY ? 0 : chrome.minY
            let boxH = flight.landedY ? size.height : chrome.height
            // Ends square so the mask never clips BubbleShape's tucked corner.
            let boxRadius = flight.landedY ? 0 : flight.chromeRadius

            ZStack(alignment: .topLeading) {
                if flight.target != nil {
                    // The composer's own box, fading out as it morphs.
                    RoundedRectangle(cornerRadius: boxRadius, style: .continuous)
                        .fill(Color.yaplySurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: boxRadius, style: .continuous)
                                .stroke(Color.yaplyAccent.opacity(0.5), lineWidth: 1.5)
                        )
                        .frame(width: boxW, height: boxH)
                        .offset(x: boxX, y: boxY)
                        .opacity(flight.filled ? 0 : 1)

                    // The finished bubble, revealed through the same morphing box.
                    BubbleContentView(
                        message: flight.message,
                        isOwn: true,
                        position: flight.position,
                        mentionMembers: mentionMembers,
                        currentUserId: currentUserId
                    )
                    .frame(width: size.width, height: size.height, alignment: .topTrailing)
                    .mask(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: boxRadius, style: .continuous)
                            .frame(width: boxW, height: boxH)
                            .offset(x: boxX, y: boxY)
                    }
                    .opacity(flight.filled ? 1 : 0)
                }

                // Composer-coloured text crossfading into the bubble's white text.
                Text(flight.message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, inset.width)
                    .padding(.vertical, inset.height)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .opacity(flight.filled ? 0 : 1)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // One offset per axis, so each rides its own curve.
            .offset(x: (flight.landedX ? end.x : start.x) - origin.x)
            .offset(y: (flight.landedY ? end.y : start.y) - origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
