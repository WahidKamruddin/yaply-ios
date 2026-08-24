import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// The QR is a convenience wrapper around the typed code, never the only path —
// it encodes a deep link so a phone's native camera app lands straight in the
// entrant flow. The code lives in the URL *fragment* so it never reaches server
// logs, proxies, or a Referer header. CoreImage generates it, so no dependency.
struct PairingQRView: View {
    let code: String
    var size: CGFloat = 180

    static func link(for code: String) -> String {
        "https://yaply.app/link#c=\(code)"
    }

    var body: some View {
        Group {
            if let image = Self.render(Self.link(for: code)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.yaplyTint)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Pairing QR code")
    }

    private static func render(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up before rasterising, or the 25×25-ish module image renders as
        // an unscannable blur.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
