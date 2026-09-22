import CoreGraphics
import Foundation

/// Knows how tall an image bubble will be *before* the image loads.
///
/// Without this the placeholder was a hard 200x140 while the loaded image sized
/// itself from its own intrinsic ratio, so every image row changed height the
/// moment it decoded — shoving everything below it and animating the shove,
/// because each row carries a `.transition` and an `.animation`.
///
/// Two sources, in order:
///  1. An `#ar=<w/h>` fragment on the media URL, written at upload time. A URL
///     fragment never reaches Supabase Storage, so this needs no schema change
///     and no new column — and an older client simply ignores it.
///  2. A ratio learned from a previous successful decode this session. This is
///     what covers images uploaded before the fragment existed, and any sent
///     from web: they jump once, then never again.
enum MediaAspectRatio {
    static let fragmentKey = "ar"

    /// Fallback shape when nothing is known yet — the old placeholder's 200x140.
    static let unknown: CGFloat = 200.0 / 140.0

    /// Clamped so a panorama or a very tall screenshot still produces a sane
    /// reserved box rather than a sliver or a wall.
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 3.0

    private static var learned: [String: CGFloat] = [:]

    static func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    /// Appends `#ar=w/h` to a freshly uploaded image's public URL.
    static func annotate(_ urlString: String, pixelSize: CGSize) -> String {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return urlString }
        // Never stack fragments if a URL somehow already carries one.
        let base = urlString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? urlString
        let ratio = clamp(pixelSize.width / pixelSize.height)
        return "\(base)#\(fragmentKey)=\(String(format: "%.4f", ratio))"
    }

    /// The ratio to lay a bubble out with, or nil when nothing is known yet.
    static func known(for urlString: String?) -> CGFloat? {
        guard let urlString else { return nil }
        if let parsed = parse(urlString) { return parsed }
        return learned[cacheKey(urlString)]
    }

    /// Records the real ratio once an image has actually decoded.
    static func remember(_ urlString: String?, size: CGSize) {
        guard let urlString, size.width > 0, size.height > 0 else { return }
        learned[cacheKey(urlString)] = clamp(size.width / size.height)
    }

    private static func parse(_ urlString: String) -> CGFloat? {
        guard let hash = urlString.range(of: "#\(fragmentKey)=") else { return nil }
        let raw = urlString[hash.upperBound...]
        // Tolerate anything appended after the value.
        let value = raw.prefix { $0.isNumber || $0 == "." }
        guard let parsed = Double(value), parsed > 0 else { return nil }
        return clamp(CGFloat(parsed))
    }

    /// The fragment is presentation metadata, not part of the object's
    /// identity, so it must not split the cache for one image.
    private static func cacheKey(_ urlString: String) -> String {
        urlString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? urlString
    }
}
