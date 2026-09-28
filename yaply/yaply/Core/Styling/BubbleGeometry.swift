import CoreGraphics

/// Geometry constants for `BubbleShape` (see `MessageBubbleView.swift`),
/// pulled out of that file so `ChatStyle` can retune bubble shape without
/// touching the path-drawing code itself.
enum BubbleGeometry {
    /// Corner radius on the "open" (non-tail) corners.
    static var radius: CGFloat {
        switch ChatStyle.current {
        case .yaply: return 18
        case .messenger, .imessage: return 20
        }
    }

    /// Corner radius on the tucked-in corner of a `.middle` grouped bubble.
    static var middleFlatRadius: CGFloat {
        switch ChatStyle.current {
        case .yaply, .messenger: return 6
        case .imessage: return 4
        }
    }

    /// Corner radius on the tucked-in corner of a `.first`/`.last` grouped
    /// bubble. iMessage's is much tighter than its open radius, which
    /// approximates a pointed tail using geometry alone (no custom Shape
    /// path segment).
    static var edgeFlatRadius: CGFloat {
        switch ChatStyle.current {
        case .yaply: return 4
        case .messenger: return 6
        case .imessage: return 2
        }
    }
}
