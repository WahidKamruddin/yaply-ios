import SwiftUI

// Vector reproduction of the real yaply "Y" mark (source of truth:
// ../../../../../public/logo.svg / src/components/YaplyLogo.tsx in the web
// repo, viewBox 0 0 196 218). Kept as a native SwiftUI Shape rather than a
// bundled image asset — matches this project's code-drawn-color convention
// and stays crisp at any size in both light and dark mode.
struct YaplyMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let viewBoxSize = CGSize(width: 196, height: 218)
        let scale = min(rect.width / viewBoxSize.width, rect.height / viewBoxSize.height)
        let offsetX = rect.minX + (rect.width - viewBoxSize.width * scale) / 2
        let offsetY = rect.minY + (rect.height - viewBoxSize.height * scale) / 2
        let transform = CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)

        var path = Path()

        path.move(to: CGPoint(x: 95.67, y: 82.25))
        path.addCurve(to: CGPoint(x: 90.2, y: 91.43), control1: CGPoint(x: 94.85, y: 85.59), control2: CGPoint(x: 92.33, y: 88.74))
        path.addCurve(to: CGPoint(x: 78.71, y: 102.49), control1: CGPoint(x: 87.02, y: 95.43), control2: CGPoint(x: 84.13, y: 101.23))
        path.addCurve(to: CGPoint(x: 66.59, y: 98.19), control1: CGPoint(x: 73.8, y: 103.64), control2: CGPoint(x: 70.29, y: 100.85))
        path.addCurve(to: CGPoint(x: 47.67, y: 84.07), control1: CGPoint(x: 60.21, y: 93.62), control2: CGPoint(x: 53.85, y: 88.91))
        path.addCurve(to: CGPoint(x: 29.27, y: 58.9), control1: CGPoint(x: 39.57, y: 77.73), control2: CGPoint(x: 25.74, y: 71.83))
        path.addCurve(to: CGPoint(x: 50.55, y: 47.27), control1: CGPoint(x: 31.65, y: 50.14), control2: CGPoint(x: 41.85, y: 44.56))
        path.addCurve(to: CGPoint(x: 66.36, y: 58.88), control1: CGPoint(x: 56.17, y: 49.02), control2: CGPoint(x: 61.87, y: 55.08))
        path.addCurve(to: CGPoint(x: 88.99, y: 76.75), control1: CGPoint(x: 73.69, y: 65.07), control2: CGPoint(x: 81.49, y: 70.77))
        path.addCurve(to: CGPoint(x: 95.67, y: 82.25), control1: CGPoint(x: 91.17, y: 78.49), control2: CGPoint(x: 93.9, y: 80.1))
        path.closeSubpath()

        path.move(to: CGPoint(x: 157.38, y: 47.21))
        path.addCurve(to: CGPoint(x: 174.69, y: 70.43), control1: CGPoint(x: 170.48, y: 44.98), control2: CGPoint(x: 181.89, y: 58.49))
        path.addCurve(to: CGPoint(x: 161.8, y: 82.04), control1: CGPoint(x: 171.64, y: 75.48), control2: CGPoint(x: 166.18, y: 78.3))
        path.addCurve(to: CGPoint(x: 135.53, y: 102.77), control1: CGPoint(x: 153.35, y: 89.25), control2: CGPoint(x: 144.32, y: 95.96))
        path.addCurve(to: CGPoint(x: 121.15, y: 115.86), control1: CGPoint(x: 130.85, y: 106.4), control2: CGPoint(x: 123.62, y: 110.29))
        path.addCurve(to: CGPoint(x: 119.79, y: 130.75), control1: CGPoint(x: 119.11, y: 120.44), control2: CGPoint(x: 119.79, y: 125.86))
        path.addCurve(to: CGPoint(x: 119.76, y: 155.75), control1: CGPoint(x: 119.78, y: 139.08), control2: CGPoint(x: 119.78, y: 147.42))
        path.addCurve(to: CGPoint(x: 119.53, y: 166.72), control1: CGPoint(x: 119.75, y: 159.25), control2: CGPoint(x: 120.32, y: 163.3))
        path.addCurve(to: CGPoint(x: 98.5, y: 178.71), control1: CGPoint(x: 117.44, y: 175.67), control2: CGPoint(x: 107.24, y: 182.11))
        path.addCurve(to: CGPoint(x: 88.24, y: 167.09), control1: CGPoint(x: 93.48, y: 176.76), control2: CGPoint(x: 89.61, y: 172.18))
        path.addCurve(to: CGPoint(x: 88.17, y: 138.75), control1: CGPoint(x: 86.98, y: 162.41), control2: CGPoint(x: 88.17, y: 144.77))
        path.addCurve(to: CGPoint(x: 89.26, y: 112.92), control1: CGPoint(x: 88.16, y: 130.46), control2: CGPoint(x: 86.91, y: 120.89))
        path.addCurve(to: CGPoint(x: 97.36, y: 97.11), control1: CGPoint(x: 90.9, y: 107.39), control2: CGPoint(x: 93.7, y: 101.66))
        path.addCurve(to: CGPoint(x: 113.26, y: 83), control1: CGPoint(x: 101.77, y: 91.65), control2: CGPoint(x: 108.08, y: 87.68))
        path.addCurve(to: CGPoint(x: 130.97, y: 67.71), control1: CGPoint(x: 119.03, y: 77.8), control2: CGPoint(x: 125.04, y: 72.73))
        path.addCurve(to: CGPoint(x: 157.38, y: 47.21), control1: CGPoint(x: 137.05, y: 62.57), control2: CGPoint(x: 150.2, y: 48.44))
        path.closeSubpath()

        return path.applying(transform)
    }
}

extension Color {
    // Logo-specific gradient stops (matches public/logo.svg exactly) — the
    // brand mark keeps these fixed colors in both light and dark mode,
    // same as the web YaplyLogo component, rather than following yaplyAccent.
    static let yaplyLogoStart = Color(red: 0.420, green: 0.659, blue: 1.0)   // #6BA8FF
    static let yaplyLogoEnd = Color(red: 0.231, green: 0.435, blue: 0.878)   // #3B6FE0
}

/// The yaply "Y" mark, matching web's `<YaplyLogo variant="mark" />`.
struct YaplyLogoMark: View {
    var size: CGFloat = 40

    var body: some View {
        YaplyMarkShape()
            .fill(
                LinearGradient(
                    colors: [Color.yaplyLogoStart, Color.yaplyLogoEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
    }
}
