import ScrollStitchCore
import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO

/// Shared by ingress, the encoder and the single PNG worker. A buffer remains
/// unavailable until every consumer releases it; no in-flight surface is reused.
public final class NativeVideoBufferPool: @unchecked Sendable {
    private let lock=NSLock()
    private var pool:CVPixelBufferPool?
    private var width=0,height=0
    public init() {}
    public func acquire(width:Int,height:Int) throws -> CVPixelBuffer {
        lock.lock();defer { lock.unlock() }
        if pool == nil {
            let attributes:[CFString:Any]=[kCVPixelBufferWidthKey:width,kCVPixelBufferHeightKey:height,
                kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey:[:],
                kCVPixelBufferMetalCompatibilityKey:true]
            guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else { throw ScrollStitchError.storageFailure }
            self.width=width;self.height=height
        }
        guard width==self.width,height==self.height,let pool else { throw ScrollStitchError.invalidDimensions }
        var buffer:CVPixelBuffer?
        let code=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,
            [kCVPixelBufferPoolAllocationThresholdKey:3] as CFDictionary,&buffer)
        if code==kCVReturnWouldExceedAllocationThreshold { throw ScrollStitchError.resourceBusy }
        guard code==kCVReturnSuccess,let buffer else { throw ScrollStitchError.storageFailure }
        return buffer
    }
}

/// ScreenCaptureKit may supply GPU-backed/encoded pixel formats which cannot be
/// copied plane-by-plane. Convert once to an owned SDR BGRA surface before either
/// PNG or video encoding. Never retain the system buffer beyond this conversion.
public struct NativeVideoSample: @unchecked Sendable {
    public let sample: CMSampleBuffer
    public let orientation: Int
    public let usedDefaultOrientation: Bool
    public let acceptedUptime:Double

    public static func number(_ key: String, in sample: CMSampleBuffer) -> NSNumber? {
        // Buffer attachments and per-sample attachments are distinct CoreMedia APIs.
        if let value = CMGetAttachment(sample, key: key as CFString, attachmentModeOut: nil) as? NSNumber {
            return value
        }
        let entries = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary]
        return entries?.first?[key] as? NSNumber
    }

    public init(copying source: CMSampleBuffer, orientationKey: String, context: CIContext, pool:NativeVideoBufferPool? = nil) throws {
        acceptedUptime=ProcessInfo.processInfo.systemUptime
        guard CMSampleBufferIsValid(source), CMSampleBufferDataIsReady(source),
              let pixel = CMSampleBufferGetImageBuffer(source) else { throw ScrollStitchError.corruptData }
        let raw = Self.number(orientationKey, in: source)
        // Unannotated buffers retain their actual pixel orientation. Do not invent
        // rotation from device posture. The sink rejects non-portrait/changed geometry.
        let orientation = raw?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw ScrollStitchError.unsupportedInput }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        var target: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                          kCVPixelBufferMetalCompatibilityKey: true]
        if let pool { target=try pool.acquire(width:width,height:height) }
        else if CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&target) != kCVReturnSuccess {
            throw ScrollStitchError.storageFailure
        }
        guard let target else { throw ScrollStitchError.storageFailure }
        let image = CIImage(cvPixelBuffer: pixel)
        context.render(image, to: target, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Rendering already converts colors; do not copy HDR/YCbCr attachments
        // onto the BGRA result and accidentally reinterpret its color space.
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: target,
            formatDescriptionOut: &description) == noErr, let description else { throw ScrollStitchError.corruptData }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: target, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &result) == noErr, let result else { throw ScrollStitchError.corruptData }
        sample = result; self.orientation = orientation; usedDefaultOrientation = raw == nil
    }
}
