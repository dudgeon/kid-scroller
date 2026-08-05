import UIKit
import SwiftUI
import SameAgeCore

/// Builds the side-by-side composite for sharing (R19).
///
/// Both ages are labelled, because the ages are the entire point of the comparison — a
/// bare side-by-side of two kids says nothing without them.
enum ShareComposer {

    struct Side {
        let image: UIImage
        let name: String
        let ageMonths: Double
    }

    /// Renders `left` and `right` at equal widths on a neutral backdrop, each captioned
    /// with the kid's name and age. Returns nil only if both images are unusable.
    static func composite(left: Side, right: Side, targetWidth: CGFloat = 2048) -> UIImage? {
        let halfWidth = targetWidth / 2
        let padding: CGFloat = targetWidth * 0.015
        let captionHeight: CGFloat = targetWidth * 0.055

        // Fit each image into its half, preserving aspect (R14's no-cropping spirit).
        func drawnSize(_ image: UIImage) -> CGSize {
            let available = halfWidth - padding * 1.5
            let scale = available / max(image.size.width, 1)
            return CGSize(width: available, height: image.size.height * scale)
        }

        let leftSize = drawnSize(left.image)
        let rightSize = drawnSize(right.image)
        let imageHeight = max(leftSize.height, rightSize.height)
        let canvas = CGSize(width: targetWidth, height: imageHeight + captionHeight + padding * 2)

        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))

            func draw(_ side: Side, size: CGSize, originX: CGFloat) {
                // Vertically centre the shorter of the two so they read as a pair.
                let y = padding + (imageHeight - size.height) / 2
                side.image.draw(in: CGRect(x: originX, y: y, width: size.width, height: size.height))

                let caption = "\(side.name) · \(AgeFormatter.short(months: side.ageMonths))"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: captionHeight * 0.42, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = caption.size(withAttributes: attributes)
                caption.draw(
                    at: CGPoint(x: originX + (size.width - textSize.width) / 2,
                                y: padding + imageHeight + (captionHeight - textSize.height) / 2),
                    withAttributes: attributes
                )
            }

            draw(left, size: leftSize, originX: padding * 0.5)
            draw(right, size: rightSize, originX: halfWidth + padding * 0.5)
        }
    }
}

/// Wraps the system share sheet so SwiftUI can present a composite image.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
