import CoreGraphics

/// Geometry constants for `BubbleShape` (see `MessageBubbleView.swift`),
/// pulled out of that file so a UI-style redesign branch can retune bubble
/// shape without touching the path-drawing code itself. Values here are
/// unchanged from what was previously inline — this is an extraction only.
enum BubbleGeometry {
    /// Corner radius on the "open" (non-tail) corners.
    static let radius: CGFloat = 18

    /// Corner radius on the tucked-in corner of a `.middle` grouped bubble.
    static let middleFlatRadius: CGFloat = 6

    /// Corner radius on the tucked-in corner of a `.first`/`.last` grouped bubble.
    static let edgeFlatRadius: CGFloat = 4
}
