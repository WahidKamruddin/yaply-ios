import SwiftUI
import UIKit

// yaply display font — mirrors the web app's `font-display` utility
// (self-hosted Bricolage Grotesque, see ../../../../../src/styles.css and
// public/fonts/BricolageGrotesque-var-latin.woff2). Reserved for
// heading/identity text only (conversation names, screen titles, wordmark) —
// body/message text always stays system font, matching the web spec.
//
// Static weight instances (Medium/SemiBold/Bold/ExtraBold) are generated
// from the web's variable woff2 source and bundled under Resources/Fonts/,
// declared in Info.plist's UIAppFonts array. PostScript names below must
// match the font files' name table exactly (see Resources/Fonts/).
private let displayFontFamily = "BricolageGrotesque"

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        let psName: String
        switch weight {
        case .heavy, .black:
            psName = "\(displayFontFamily)-ExtraBold"
        case .bold:
            psName = "\(displayFontFamily)-Bold"
        case .medium:
            // Matches web's `.lp-nav-brand` wordmark weight (font-weight: 500)
            psName = "\(displayFontFamily)-Medium"
        default:
            psName = "\(displayFontFamily)-SemiBold"
        }
        if UIFont(name: psName, size: size) != nil {
            return Font.custom(psName, size: size)
        }
        // Fallback in case the bundled font ever fails to register — rounded
        // system font reads closer to a display face than the plain system
        // font.
        return Font.system(size: size, weight: weight, design: .rounded)
    }
}
