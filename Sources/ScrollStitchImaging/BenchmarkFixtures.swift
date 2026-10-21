import Foundation
import CoreGraphics
import ImageIO
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public enum BenchmarkFixtures {
    /// Draw known global rows: 19 frames at 960 px advance represent exactly ten screens.
    public static func writePNG(_ url: URL, width: Int, height: Int, offset: Int, seed: Int,
                                cancelled: () -> Bool = { false }) throws {
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScrollStitchError.budgetExceeded
        }
        for row in 0..<height {
            if row % 128 == 0 { if cancelled() { throw ScrollStitchError.cancelled } }
            for band in 0..<6 {
                let n=UInt32(truncatingIfNeeded:(row+offset+1000)*73856093 ^ (band+seed)*19349663)
                let hash=(n ^ (n >> 13)) &* 1274126177
                context.setFillColor(CGColor(red:CGFloat(hash & 255)/255,
                    green:CGFloat((hash >> 8)&255)/255,blue:CGFloat((hash >> 16)&255)/255,alpha:1))
                let x0=band*width/6,x1=(band+1)*width/6
                context.fill(CGRect(x:x0,y:height-row-1,width:x1-x0,height:1))
            }
        }
        guard let image=context.makeImage(),
              let writer=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else {
            throw ScrollStitchError.storageFailure
        }
        CGImageDestinationAddImage(writer,image,nil)
        guard CGImageDestinationFinalize(writer) else { throw ScrollStitchError.storageFailure }
    }
}
