import UIKit

extension UIImage {
    /// Scales the image down so its longest edge is at most `maxDimension` **pixels**.
    ///
    /// The pixel/point distinction is load-bearing. `UIGraphicsImageRenderer(size:)`
    /// with no `format:` inherits the device's display scale, and its `size:` is in
    /// points — so on a 3x iPhone the old version of this function produced a
    /// backing `CGImage` three times larger than asked for (`maxDimension: 1280`
    /// → a 3840px image), which `jpegData` then encoded in full. That shipped ~9x
    /// the pixels per upload and left a ~44MB bitmap to decode on display.
    /// `format.scale = 1` makes `target` mean pixels, matching the web client's
    /// canvas resize in `src/features/media/api/upload.ts`.
    nonisolated func resized(maxDimension: CGFloat) -> UIImage {
        // `size` is in points; the real pixel dimensions are size * scale. A
        // pasted or camera-captured image can arrive at any scale, so normalise
        // before deciding whether a resize is needed at all.
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        guard pixelWidth > 0, pixelHeight > 0 else { return self }

        let factor = min(maxDimension / pixelWidth, maxDimension / pixelHeight, 1.0)
        guard factor < 1.0 else { return self }

        let target = CGSize(
            width: max(1, (pixelWidth * factor).rounded()),
            height: max(1, (pixelHeight * factor).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // Stickers rely on their alpha channel; photos don't, and an opaque
        // buffer is cheaper. `.standard` avoids a 16-bit wide-gamut buffer,
        // which would double the memory for no visible gain in a chat bubble.
        format.opaque = !hasAlpha
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// True when the image has an alpha channel — used to tell a transparent
    /// sticker apart from an opaque photo on paste / drop.
    nonisolated var hasAlpha: Bool {
        guard let alpha = cgImage?.alphaInfo else { return false }
        switch alpha {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    /// Longest edge in pixels, for the aspect-ratio hint attached at upload time.
    nonisolated var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// One home for every "shrink this before uploading" decision.
///
/// These numbers used to be copy-pasted across five call sites (chat paste,
/// camera, PhotosPicker, drag-and-drop, the media picker sheet) and had already
/// drifted from the avatar and sticker paths. They must also stay in step with
/// the web client's `compressImage` (`src/features/media/api/upload.ts`), since
/// both platforms write into the same `media` bucket.
///
/// Every entry point is `async` and hops off the main actor: these calls decode,
/// redraw and re-encode a full-resolution photo, and they were previously
/// running inline on the main thread from SwiftUI view closures.
nonisolated enum MediaEncoding {
    /// Longest edge, in pixels, of an uploaded photo. Matches the web client.
    static let photoMaxDimension: CGFloat = 1280
    static let photoQuality: CGFloat = 0.82
    /// Stickers and avatars are displayed small; 512 is plenty.
    static let smallMaxDimension: CGFloat = 512
    static let avatarQuality: CGFloat = 0.8

    /// Resize + JPEG-encode a photo for upload. Returns the bytes and the pixel
    /// size actually encoded (the caller attaches the latter to the media URL so
    /// the bubble can reserve the right height before the image loads).
    static func photoJPEG(_ image: UIImage) async -> (data: Data, size: CGSize)? {
        await Task.detached(priority: .userInitiated) {
            let scaled = image.resized(maxDimension: photoMaxDimension)
            guard let data = scaled.jpegData(compressionQuality: photoQuality) else { return nil }
            return (data, scaled.pixelSize)
        }.value
    }

    /// Same, starting from the raw bytes a picker hands back — the decode happens
    /// off the main actor too, which is where most of the cost is for a 12MP photo.
    static func photoJPEG(from data: Data) async -> (data: Data, size: CGSize)? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let scaled = image.resized(maxDimension: photoMaxDimension)
            guard let encoded = scaled.jpegData(compressionQuality: photoQuality) else { return nil }
            return (encoded, scaled.pixelSize)
        }.value
    }

    /// Stickers keep their alpha, so PNG rather than JPEG.
    static func stickerPNG(_ image: UIImage) async -> (data: Data, size: CGSize)? {
        await Task.detached(priority: .userInitiated) {
            let scaled = image.resized(maxDimension: smallMaxDimension)
            guard let data = scaled.pngData() else { return nil }
            return (data, scaled.pixelSize)
        }.value
    }

    /// Avatars also need the scaled `UIImage` back for the local preview.
    static func avatarJPEG(from data: Data) async -> (data: Data, image: UIImage)? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let scaled = image.resized(maxDimension: smallMaxDimension)
            guard let encoded = scaled.jpegData(compressionQuality: avatarQuality) else { return nil }
            return (encoded, scaled)
        }.value
    }
}
