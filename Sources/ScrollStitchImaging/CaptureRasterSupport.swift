#if !canImport(UIKit)
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

private final class CanvasBox: NSObject {
    let context: CGContext
    init(_ context: CGContext) { self.context = context }
}
private var canvas: CGContext { (Thread.current.threadDictionary["scrollstitch.canvas"] as! CanvasBox).context }

struct UIImage {
    enum Orientation { case up, leftMirrored }
    let cgImage: CGImage?
    var size: CGSize { CGSize(width: cgImage!.width, height: cgImage!.height) }
    init(cgImage: CGImage, scale: CGFloat = 1, orientation: Orientation = .up) {
        if orientation == .leftMirrored {
            let image = CIImage(cgImage: cgImage).oriented(.leftMirrored)
            self.cgImage = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
        } else { self.cgImage = cgImage }
    }
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cgImage = image
    }
    init?(contentsOfFile path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        self.init(data: data)
    }
    func draw(at point: CGPoint) { draw(in: CGRect(origin: point, size: size)) }
    func draw(in rect: CGRect) {
        let c = canvas
        c.saveGState()
        c.translateBy(x: rect.minX, y: rect.maxY)
        c.scaleBy(x: 1, y: -1)
        c.interpolationQuality = .none
        c.draw(cgImage!, in: CGRect(origin: .zero, size: rect.size))
        c.restoreGState()
    }
    func jpegData(compressionQuality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let image = cgImage, let writer = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        return CGImageDestinationFinalize(writer) ? data as Data : nil
    }
}
struct UIColor {
    let white: CGFloat, alpha: CGFloat
    static var white: UIColor { UIColor(white: 1, alpha: 1) }
    static var systemBackground: UIColor { .white }
    func setFill() { canvas.setFillColor(gray: white, alpha: alpha) }
}
final class UIGraphicsImageRendererFormat {
    enum Range { case standard }
    var scale: CGFloat = 1
    var opaque = true
    var preferredRange = Range.standard
}
struct UIGraphicsImageRendererContext {
    let cgContext: CGContext
    func fill(_ rect: CGRect) { cgContext.fill(rect) }
}
struct UIGraphicsImageRenderer {
    let size: CGSize
    let format: UIGraphicsImageRendererFormat
    func image(actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let c = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                          bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.translateBy(x: 0, y: size.height)
        c.scaleBy(x: 1, y: -1)
        let prior = Thread.current.threadDictionary["scrollstitch.canvas"]
        Thread.current.threadDictionary["scrollstitch.canvas"] = CanvasBox(c)
        defer { Thread.current.threadDictionary["scrollstitch.canvas"] = prior }
        actions(UIGraphicsImageRendererContext(cgContext: c))
        return UIImage(cgImage: c.makeImage()!)
    }
}

#endif
