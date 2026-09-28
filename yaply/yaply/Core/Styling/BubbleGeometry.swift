import CoreGraphics

/// Geometry constants for `BubbleShape` (see `MessageBubbleView.swift`),
/// pulled out of that file so a UI-style redesign branch can retune bubble
/// shape without touching the path-drawing code itself.
///
/// Values tuned for ui/messenger-style: a slightly larger radius and a
/// softer edge-tuck read closer to Messenger's fully-rounded pill bubbles.
enum BubbleGeometry {
    /// Corner radius on the "open" (non-tail) corners.
    static let radius: CGFloat = 20

    /// Corner radius on the tucked-in corner of a `.middle` grouped bubble.
    static let middleFlatRadius: CGFloat = 6

    /// Corner radius on the tucked-in corner of a `.first`/`.last` grouped bubble.
    static let edgeFlatRadius: CGFloat = 6
}
