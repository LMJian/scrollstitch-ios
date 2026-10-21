import Foundation
import CoreGraphics
import ImageIO
import Darwin
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public enum ImageFormat: String, Codable, CaseIterable, Sendable { case png, jpeg }
public struct ExportArtifact: Sendable {
    public let taskID: UUID
    public let revision: UInt64
    public let url: URL
    public let size: PixelSize
    public let sizeBytes: Int
    public let sha256: String
    public let format: ImageFormat
}
public enum ImageDecoder {
    public static func normalized(_ url: URL, maxDimension: Int? = nil) throws -> CGImage {
        let info = try ImageImporter.inspect(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceShouldCacheImmediately:true,
                kCGImageSourceThumbnailMaxPixelSize:maxDimension ?? max(info.size.width,info.size.height)
              ] as CFDictionary) else { throw ScrollStitchError.corruptData }
        return image
    }
    public static func raster(_ url: URL) throws -> FrameRaster {
        try autoreleasepool {
        let image = try normalized(url), size = try PixelSize(width:image.width,height:image.height)
        var bytes = [UInt8](repeating:0,count:size.pixels*4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data:buffer.baseAddress,width:size.width,height:size.height,bitsPerComponent:8,
                bytesPerRow:size.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ScrollStitchError.budgetExceeded
            }
            context.draw(image,in:CGRect(x:0,y:0,width:size.width,height:size.height))
        }
        return try FrameRaster(size:size,rgba:bytes)
        }
    }
}

public enum ImageRenderer {
    // The 0.92 candidate failed boundary-color checks on the device fixture.
    // Quality 1.0 passes the unchanged tolerance; JPEG is still a lossy format.
    public static let jpegQuality = 1.0
    public static func render(_ plan: CompositionPlan, store: TaskStore, format: ImageFormat,
                              cancelled: () -> Bool = { false }) throws -> ExportArtifact {
        try plan.validate()
        if cancelled() { throw ScrollStitchError.cancelled }
        let lease = try store.acquireShareLease(taskID:plan.taskID)
        return try withExtendedLifetime(lease) {
            try assertCurrent(plan,store:store)
            let taskDirectory=try store.taskDirectory(plan.taskID)
            if FileManager.default.fileExists(atPath:taskDirectory.appendingPathComponent("recording/index.json").path) {
                // New video-backed captures reserve both the old outputs and this
                // temporary encoding. Never delete an existing work to make space.
                let used=try CaptureStorageBudget.diskBytes(in:taskDirectory)
                guard plan.size.pixels*4+1024*1024<=CaptureStorageBudget.taskBudget-used else { throw ScrollStitchError.budgetExceeded }
            }
            guard let colorSpace = CGColorSpace(name:CGColorSpace.sRGB),
                  let context = CGContext(data:nil,width:plan.size.width,height:plan.size.height,bitsPerComponent:8,
                    bytesPerRow:plan.size.width*4,space:colorSpace,
                    bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ScrollStitchError.budgetExceeded
            }
            let value: CGFloat = plan.background == .white ? 1 : 0
            context.setFillColor(CGColor(gray:value,alpha:1))
            context.fill(CGRect(x:0,y:0,width:plan.size.width,height:plan.size.height))
            context.interpolationQuality = .high
            for item in plan.items {
                if cancelled() { throw ScrollStitchError.cancelled }
                try autoreleasepool {
                    let url = try store.assetURL(item.input.asset,taskID:plan.taskID)
                    let info = try ImageImporter.inspect(url)
                    guard info.size == item.input.asset.size else { throw ScrollStitchError.corruptData }
                    let scale = Double(plan.size.width)/Double(item.input.crop.width)
                    let maxDimension = Int(ceil(Double(max(info.size.width,info.size.height))*scale))
                    let image = try ImageDecoder.normalized(url,maxDimension:maxDimension)
                    let sx = Double(image.width)/Double(info.size.width), sy = Double(image.height)/Double(info.size.height)
                    let crop = item.input.crop
                    let x0 = Int((Double(crop.x)*sx).rounded()), y0 = Int((Double(crop.y)*sy).rounded())
                    let x1 = Int((Double(crop.x+crop.width)*sx).rounded()), y1 = Int((Double(crop.y+crop.height)*sy).rounded())
                    guard let clipped = image.cropping(to:CGRect(x:x0,y:y0,width:max(1,x1-x0),height:max(1,y1-y0))) else {
                        throw ScrollStitchError.invalidDimensions
                    }
                    // Quartz uses a bottom-left drawing origin; layout y is measured from the top.
                    context.draw(clipped,in:CGRect(x:0,y:plan.size.height-item.y-item.height,width:plan.size.width,height:item.height))
                }
            }
            if cancelled() { throw ScrollStitchError.cancelled }
            guard let image = context.makeImage() else { throw ScrollStitchError.budgetExceeded }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var key = try encoder.encode(plan); key.append(contentsOf:format.rawValue.utf8)
            if format == .jpeg {
                key.append(0)
                key.append(try encoder.encode(jpegQuality))
            }
            let filename = TaskStore.digest(data:key) + "." + format.rawValue
            let directory = try store.taskDirectory(plan.taskID)
            let temporary = try AssetPath("temporary/" + UUID().uuidString + "." + format.rawValue).resolved(in:directory)
            let destination = try AssetPath("exports/" + filename).resolved(in:directory)
            defer { try? FileManager.default.removeItem(at:temporary) }
            guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL,
                (format == .png ? "public.png" : "public.jpeg") as CFString,1,nil) else { throw ScrollStitchError.storageFailure }
            let properties: [CFString:Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality:jpegQuality] : [:]
            // Never copy source EXIF/GPS dictionaries into the destination.
            CGImageDestinationAddImage(writer,image,properties as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw ScrollStitchError.storageFailure }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:temporary.path)
            #endif
            var protectedURL = temporary, values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
            let written = try ImageImporter.inspect(temporary)
            guard written.size == plan.size, written.orientation == 1 else { throw ScrollStitchError.corruptData }
            let handle = try FileHandle(forWritingTo:temporary); try handle.synchronize(); try handle.close()
            if cancelled() { throw ScrollStitchError.cancelled }
            try assertCurrent(plan,store:store)
            guard rename(temporary.path,destination.path) == 0 else { throw ScrollStitchError.storageFailure }
            let count = (try FileManager.default.attributesOfItem(atPath:destination.path)[.size] as? NSNumber)?.intValue ?? 0
            guard count > 0 else { throw ScrollStitchError.corruptData }
            return ExportArtifact(taskID:plan.taskID,revision:plan.revision,url:destination,size:plan.size,
                sizeBytes:count,sha256:try TaskStore.digest(url:destination),format:format)
        }
    }
    private static func assertCurrent(_ plan: CompositionPlan, store: TaskStore) throws {
        guard let manifest = try store.current(), manifest.taskID == plan.taskID, manifest.kind == plan.kind,
              !manifest.pendingCleanup, !manifest.deleting else { throw ScrollStitchError.staleOperation }
        if plan.kind == .collage {
            let edit = try store.editSnapshot(taskID:plan.taskID)
            guard edit.revision == plan.revision else { throw ScrollStitchError.revisionConflict }
            guard edit.unresolvedImports == 0, edit.activeImport == nil else { throw ScrollStitchError.invalidSelection }
        } else {
            let snapshot = try store.reconcileCapture(taskID:plan.taskID)
            guard snapshot.phase == .ended || snapshot.phase == .interrupted else { throw ScrollStitchError.captureActive }
            guard snapshot.sequence == plan.revision else { throw ScrollStitchError.revisionConflict }
        }
    }
}
