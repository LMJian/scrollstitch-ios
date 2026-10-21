import ScrollStitchCore
import Foundation
@preconcurrency import AVFoundation
import CoreVideo

/// Serial, video-only, three-second transactions. A killed encoder can lose only
/// the uncommitted chunk; the PNG snapshot and previously indexed chunks survive.
public final class CaptureVideoArchive {
    public static let taskBudget=256*1024*1024
    // Leave room for one maximum-size image and file transactions after capture.
    public static let materialBudget=128*1024*1024
    public static let captureBudget=materialBudget-1024*1024
    public static let chunkReserve=8*1024*1024
    public private(set) var committedBytes=0
    public var reservedBytes:Int { committedBytes + (writer == nil ? 0:Self.chunkReserve) }
    private let directory:URL
    private var index=CaptureVideoIndex()
    private var timeline=CaptureTimeline()
    private var pendingTimeline=[CaptureTimeline.Sample]()
    private var writer:AVAssetWriter?
    private var input:AVAssetWriterInput?
    private var pool:CVPixelBufferPool?
    private var currentURL:URL?
    private var start:CMTime = .invalid
    private var last:CMTime = .invalid
    private var orientation=1
    public init(taskDirectory:URL) throws {
        directory=taskDirectory.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Self.protect(directory);try publishIndex()
    }
    private static func protect(_ url:URL) throws {
        var u=url,values=URLResourceValues();values.isExcludedFromBackup=true;try u.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        #endif
    }
    public static func diskBytes(in directory:URL) throws -> Int {
        let keys:[URLResourceKey]=[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]
        guard let files=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:keys) else { throw ScrollStitchError.storageFailure }
        var result=0
        for case let file as URL in files {
            let values=try file.resourceValues(forKeys:Set(keys))
            guard values.isSymbolicLink != true else { throw ScrollStitchError.invalidPath }
            if values.isRegularFile == true { result+=values.fileSize ?? 0 }
        }
        return result
    }
    private func publishIndex() throws {
        let data=try JSONEncoder().encode(index),url=directory.appendingPathComponent("index.json")
        try data.write(to:url,options:.atomic);try Self.protect(url)
        try timeline.validate()
        let timeURL=directory.appendingPathComponent("timeline-v2.json")
        try JSONEncoder().encode(timeline).write(to:timeURL,options:.atomic);try Self.protect(timeURL)
    }
    private func dropped(_ pts:CMTime,reason:String = "encoderBackpressure") {
        timeline.event(reason,lower:pts.seconds,upper:pts.seconds)
        index.droppedSamples+=1
        let lower=last.isValid ? min(last.seconds,pts.seconds):pts.seconds
        if let tail=index.droppedTimeRanges.last,lower<=tail[1]+0.001 {
            index.droppedTimeRanges[index.droppedTimeRanges.count-1][1]=max(tail[1],pts.seconds)
        } else if index.droppedTimeRanges.count<512 { index.droppedTimeRanges.append([lower,pts.seconds]) }
    }
    /// Bounded metadata for samples discarded by the native backpressure gate.
    public func recordDroppedSamples(count:Int,lower:Double,upper:Double) {
        guard count>0,lower.isFinite,upper.isFinite,lower>=0,upper>=lower else { return }
        timeline.event("ingressBackpressure",count:count,lower:lower,upper:upper)
        index.droppedSamples += min(count,1_000_000)
        if let tail=index.droppedTimeRanges.last,lower<=tail[1]+0.001 {
            index.droppedTimeRanges[index.droppedTimeRanges.count-1][1]=max(tail[1],upper)
        } else if index.droppedTimeRanges.count<512 { index.droppedTimeRanges.append([lower,upper]) }
    }
    /// Returns false before starting a chunk that cannot fit in the shared budget.
    public func append(_ sample:CMSampleBuffer,orientation:Int,availableBytes:Int,ownedBuffer:Bool = false) throws -> Bool {
        guard let source=CMSampleBufferGetImageBuffer(sample) else { throw ScrollStitchError.corruptData }
        let pts=CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric,pts.seconds.isFinite,pts.seconds>=0 else { throw ScrollStitchError.corruptData }
        if last.isValid,pts<=last { dropped(pts,reason:"nonMonotonicPTS");return true }
        if last.isValid,pts.seconds-last.seconds<1.0/30-0.000001 { timeline.event("cadenceLimit",lower:pts.seconds,upper:pts.seconds);return true }
        let previousCommittedBytes=committedBytes
        if writer != nil,pts.seconds-start.seconds>=3 { try seal() }
        if writer == nil {
            guard availableBytes-(committedBytes-previousCommittedBytes)>=Self.chunkReserve else { return false }
            try begin(source,pts:pts,orientation:orientation)
        }
        guard let writer,let input else { throw ScrollStitchError.storageFailure }
        guard writer.status == .writing else { throw writer.error ?? ScrollStitchError.storageFailure }
        guard input.isReadyForMoreMediaData else { dropped(pts);return true }
        // Never queue system-owned buffers. The pool bounds copies retained by the encoder.
        var owned:CVPixelBuffer?
        if ownedBuffer { owned=source }
        else {
            guard let pool else { throw ScrollStitchError.storageFailure }
            let aux=[kCVPixelBufferPoolAllocationThresholdKey:2] as CFDictionary
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil,pool,aux,&owned)==kCVReturnSuccess,let value=owned else {
                dropped(pts);return true
            }
            try Self.copyPixels(source,to:value)
            CVBufferPropagateAttachments(source,value)
        }
        guard let owned else { throw ScrollStitchError.storageFailure }
        var description:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:owned,formatDescriptionOut:&description)==noErr,
              let description else { throw ScrollStitchError.corruptData }
        var timing=CMSampleTimingInfo(duration:CMSampleBufferGetDuration(sample),presentationTimeStamp:CMTimeSubtract(pts,start),decodeTimeStamp:.invalid)
        var copied:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:owned,formatDescription:description,
            sampleTiming:&timing,sampleBufferOut:&copied)==noErr,let copied else { throw ScrollStitchError.corruptData }
        guard input.append(copied) else { throw writer.error ?? ScrollStitchError.storageFailure }
        pendingTimeline.append(CaptureTimeline.Sample(value:pts.value,timescale:pts.timescale,segment:index.segments.count,
            width:CVPixelBufferGetWidth(source),height:CVPixelBufferGetHeight(source),orientation:orientation))
        last=pts
        return true
    }
    private func begin(_ buffer:CVPixelBuffer,pts:CMTime,orientation:Int) throws {
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
        let url=directory.appendingPathComponent(UUID().uuidString+".partial.mov")
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[
                AVVideoAverageBitRateKey:min(12_000_000,max(4_000_000,width*height*5)),
                AVVideoMaxKeyFrameIntervalDurationKey:1,AVVideoAllowFrameReorderingKey:false]])
        input.expectsMediaDataInRealTime=true
        guard writer.canAdd(input) else { throw ScrollStitchError.unsupportedInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ScrollStitchError.storageFailure }
        writer.startSession(atSourceTime:.zero)
        // Some writer backends create the file only after the first append.
        // The protected parent directory already covers that interval.
        if FileManager.default.fileExists(atPath:url.path) { try Self.protect(url) }
        let attributes:[CFString:Any]=[kCVPixelBufferWidthKey:width,kCVPixelBufferHeightKey:height,
            kCVPixelBufferPixelFormatTypeKey:CVPixelBufferGetPixelFormatType(buffer),kCVPixelBufferIOSurfacePropertiesKey:[:]]
        var pool:CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&pool)==kCVReturnSuccess else {
            writer.cancelWriting();throw ScrollStitchError.storageFailure
        }
        self.writer=writer;self.input=input;self.pool=pool;currentURL=url;start=pts;last = .invalid;self.orientation=orientation
    }
    public func finish() throws { try seal();index.finished=true;timeline.finished=true;try publishIndex() }
    private func seal() throws {
        guard let writer,let input,let url=currentURL else { return }
        defer { self.writer=nil;self.input=nil;pool=nil;currentURL=nil }
        guard last.isValid else { writer.cancelWriting();try? FileManager.default.removeItem(at:url);return }
        input.markAsFinished()
        let semaphore=DispatchSemaphore(value:0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout:.now()+3) == .success,writer.status == .completed else {
            writer.cancelWriting();throw writer.error ?? ScrollStitchError.storageFailure
        }
        let bytes=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard bytes>0,bytes<=Self.chunkReserve else { throw ScrollStitchError.budgetExceeded }
        let name=url.lastPathComponent.replacingOccurrences(of:".partial.mov",with:".mov")
        let completed=directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at:url,to:completed);try Self.protect(completed)
        let segment=CaptureVideoSegment(path:try AssetPath("recording/"+name),startPTS:start.seconds,endPTS:last.seconds,
            orientation:orientation,bytes:bytes,sha256:try TaskStore.digest(url:completed))
        index.segments.append(segment);committedBytes+=bytes
        timeline.segmentHashes.append(segment.sha256);timeline.acceptedSourceSamples.append(contentsOf:pendingTimeline);pendingTimeline=[]
        try publishIndex()
    }
    private static func copyPixels(_ source:CVPixelBuffer,to target:CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(source,.readOnly)==kCVReturnSuccess else { throw ScrollStitchError.corruptData }
        defer { CVPixelBufferUnlockBaseAddress(source,.readOnly) }
        guard CVPixelBufferLockBaseAddress(target,[])==kCVReturnSuccess else { throw ScrollStitchError.corruptData }
        defer { CVPixelBufferUnlockBaseAddress(target,[]) }
        let count=CVPixelBufferGetPlaneCount(source)
        for plane in 0..<max(1,count) {
            let a=count==0 ? CVPixelBufferGetBaseAddress(source):CVPixelBufferGetBaseAddressOfPlane(source,plane)
            let b=count==0 ? CVPixelBufferGetBaseAddress(target):CVPixelBufferGetBaseAddressOfPlane(target,plane)
            let ar=count==0 ? CVPixelBufferGetBytesPerRow(source):CVPixelBufferGetBytesPerRowOfPlane(source,plane)
            let br=count==0 ? CVPixelBufferGetBytesPerRow(target):CVPixelBufferGetBytesPerRowOfPlane(target,plane)
            let rows=count==0 ? CVPixelBufferGetHeight(source):CVPixelBufferGetHeightOfPlane(source,plane)
            guard let a,let b else { throw ScrollStitchError.corruptData }
            for row in 0..<rows { memcpy(b.advanced(by:row*br),a.advanced(by:row*ar),min(ar,br)) }
        }
    }
    deinit { writer?.cancelWriting() }
}
