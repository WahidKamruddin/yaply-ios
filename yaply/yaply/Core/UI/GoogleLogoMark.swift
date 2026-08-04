import SwiftUI

// Vector reproduction of Google's official multi-color "G" mark (the
// standard 18x18 glyph used on "Sign in with Google" buttons per Google's
// brand guidelines). Traced as four Shape paths rather than a bundled image
// asset, matching this project's code-drawn-color convention.
private func fitTransform(in rect: CGRect, viewBox: CGSize = CGSize(width: 18, height: 18)) -> CGAffineTransform {
    let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
    let offsetX = rect.minX + (rect.width - viewBox.width * scale) / 2
    let offsetY = rect.minY + (rect.height - viewBox.height * scale) / 2
    return CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
}

private struct GoogleBluePath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 17.64, y: 9.2045))
        path.addCurve(to: CGPoint(x: 17.4764, y: 7.3636), control1: CGPoint(x: 17.64, y: 8.5664), control2: CGPoint(x: 17.5827, y: 7.9527))
        path.addLine(to: CGPoint(x: 9, y: 7.3636))
        path.addLine(to: CGPoint(x: 9, y: 10.845))
        path.addLine(to: CGPoint(x: 13.8436, y: 10.845))
        path.addCurve(to: CGPoint(x: 12.0477, y: 13.5614), control1: CGPoint(x: 13.635, y: 11.97), control2: CGPoint(x: 13.0009, y: 12.9232))
        path.addLine(to: CGPoint(x: 12.0477, y: 15.8195))
        path.addLine(to: CGPoint(x: 14.9564, y: 15.8195))
        path.addCurve(to: CGPoint(x: 17.64, y: 9.2045), control1: CGPoint(x: 16.6582, y: 14.2527), control2: CGPoint(x: 17.64, y: 11.9455))
        path.closeSubpath()
        return path.applying(fitTransform(in: rect))
    }
}

private struct GoogleGreenPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 18))
        path.addCurve(to: CGPoint(x: 14.9564, y: 15.8195), control1: CGPoint(x: 11.43, y: 18), control2: CGPoint(x: 13.4673, y: 17.1941))
        path.addLine(to: CGPoint(x: 12.0477, y: 13.5614))
        path.addCurve(to: CGPoint(x: 9.0, y: 14.4205), control1: CGPoint(x: 11.2418, y: 14.1014), control2: CGPoint(x: 10.2109, y: 14.4205))
        path.addCurve(to: CGPoint(x: 3.9641, y: 10.7101), control1: CGPoint(x: 6.6564, y: 14.4205), control2: CGPoint(x: 4.6718, y: 12.8383))
        path.addLine(to: CGPoint(x: 0.9573, y: 10.7101))
        path.addLine(to: CGPoint(x: 0.9573, y: 13.0419))
        path.addCurve(to: CGPoint(x: 9, y: 18), control1: CGPoint(x: 2.4382, y: 15.9832), control2: CGPoint(x: 5.4818, y: 18))
        path.closeSubpath()
        return path.applying(fitTransform(in: rect))
    }
}

private struct GoogleYellowPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3.9641, y: 10.71))
        path.addCurve(to: CGPoint(x: 3.6814, y: 9.0), control1: CGPoint(x: 3.7841, y: 10.17), control2: CGPoint(x: 3.6814, y: 9.5932))
        path.addCurve(to: CGPoint(x: 3.9641, y: 7.29), control1: CGPoint(x: 3.6814, y: 8.4068), control2: CGPoint(x: 3.7841, y: 7.83))
        path.addLine(to: CGPoint(x: 3.9641, y: 4.9582))
        path.addLine(to: CGPoint(x: 0.9573, y: 4.9582))
        path.addCurve(to: CGPoint(x: 0, y: 9), control1: CGPoint(x: 0.3477, y: 6.1732), control2: CGPoint(x: 0, y: 7.5477))
        path.addCurve(to: CGPoint(x: 0.9573, y: 13.0418), control1: CGPoint(x: 0, y: 10.4523), control2: CGPoint(x: 0.3477, y: 11.8268))
        path.addLine(to: CGPoint(x: 3.9641, y: 10.71))
        path.closeSubpath()
        return path.applying(fitTransform(in: rect))
    }
}

private struct GoogleRedPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 3.5795))
        path.addCurve(to: CGPoint(x: 12.4405, y: 4.9255), control1: CGPoint(x: 10.3214, y: 3.5795), control2: CGPoint(x: 11.5077, y: 4.0336))
        path.addLine(to: CGPoint(x: 15.0219, y: 2.3441))
        path.addCurve(to: CGPoint(x: 9, y: 0), control1: CGPoint(x: 13.4632, y: 0.8918), control2: CGPoint(x: 11.4259, y: 0))
        path.addCurve(to: CGPoint(x: 0.9573, y: 4.9582), control1: CGPoint(x: 5.4818, y: 0), control2: CGPoint(x: 2.4382, y: 2.0168))
        path.addLine(to: CGPoint(x: 3.9641, y: 7.29))
        path.addCurve(to: CGPoint(x: 9, y: 3.5795), control1: CGPoint(x: 4.6718, y: 5.1618), control2: CGPoint(x: 6.6564, y: 3.5795))
        path.closeSubpath()
        return path.applying(fitTransform(in: rect))
    }
}

/// The official Google "G" mark, for use on "Sign in with Google" buttons.
struct GoogleLogoMark: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            GoogleBluePath().fill(Color(red: 0.259, green: 0.522, blue: 0.957))
            GoogleGreenPath().fill(Color(red: 0.204, green: 0.659, blue: 0.325))
            GoogleYellowPath().fill(Color(red: 0.984, green: 0.737, blue: 0.020))
            GoogleRedPath().fill(Color(red: 0.918, green: 0.263, blue: 0.208))
        }
        .frame(width: size, height: size)
    }
}
