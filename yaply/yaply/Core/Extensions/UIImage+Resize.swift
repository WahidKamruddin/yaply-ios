import UIKit

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        guard scale < 1.0 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
