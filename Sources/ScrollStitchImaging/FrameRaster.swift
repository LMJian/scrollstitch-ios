import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public struct FrameRaster: Sendable {
    public let size: PixelSize
    public let rgba: [UInt8]
    public init(size: PixelSize, rgba: [UInt8]) throws {
        guard size.pixels <= 48_000_000, rgba.count == size.pixels*4 else { throw ScrollStitchError.invalidDimensions }
        self.size = size; self.rgba = rgba
    }
    init(image:CGImage) throws {
        let size=try PixelSize(width:image.width,height:image.height)
        var bytes=[UInt8](repeating:0,count:size.pixels*4)
        try bytes.withUnsafeMutableBytes {
            guard let context=CGContext(data:$0.baseAddress,width:size.width,height:size.height,
                bitsPerComponent:8,bytesPerRow:size.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ScrollStitchError.budgetExceeded
            }
            context.draw(image,in:CGRect(x:0,y:0,width:size.width,height:size.height))
        }
        try self.init(size:size,rgba:bytes)
    }
    func luma(_ x: Int,_ y: Int) -> Int {
        let p = (y*size.width+x)*4
        return (77*Int(rgba[p])+150*Int(rgba[p+1])+29*Int(rgba[p+2]))/256
    }
    func cropped(_ crop: PixelCrop?) throws -> FrameRaster {
        guard let crop else { return self }
        try crop.validate(in:size)
        if crop == PixelCrop(width:size.width,height:size.height) { return self }
        var pixels=[UInt8]();pixels.reserveCapacity(crop.width*crop.height*4)
        for y in crop.y..<(crop.y+crop.height) {
            let offset=(y*size.width+crop.x)*4
            pixels.append(contentsOf:rgba[offset..<(offset+crop.width*4)])
        }
        return try FrameRaster(size:PixelSize(width:crop.width,height:crop.height),rgba:pixels)
    }
}
