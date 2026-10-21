import ScrollStitchCore
import Foundation
import CoreMedia
import CoreImage
import ImageIO

/// Framework-independent video consumer. Frame/timer/stop writes are serialized.
/// No system-owned sample survives consume(); audio is never an input.
public final class CaptureSampleSink: @unchecked Sendable {
    public let taskID: UUID
    private let lock = NSRecursiveLock()
    private var capture: CaptureSession?
    private var archive: CaptureVideoArchive?
    private var motion = CaptureMotionSampler()
    private var geometry: CGSize?
    private var orientation: Int?
    private var deadline: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onStop: @Sendable (CaptureEndReason) -> Void
    private let diagnostics: CaptureStartupDiagnostics?
    private var committedFrames = 0
    private var committedVideo=false
    public var onFirstCommittedFrame: (@Sendable ()->Void)?
    public var onStopRequested:(@Sendable (CaptureEndReason)->Void)?
    private let pngQueue=DispatchQueue(label:"ScrollStitch.png-worker",qos:.utility)
    private var pngPending=false,closing=false
    private var completions:[@Sendable ()->Void]=[]
    private let began=ProcessInfo.processInfo.systemUptime
    public var hasCommittedFrames: Bool { lock.lock(); defer { lock.unlock() }; return committedFrames > 0 || committedVideo }

    public init(store: TaskStore, diagnostics: CaptureStartupDiagnostics? = nil,
                onStop: @escaping @Sendable (CaptureEndReason) -> Void) throws {
        self.onStop = onStop
        self.diagnostics = diagnostics
        let capture = try CaptureSession(store: store,uptime:began,
            limits: CaptureLimits(bytes: CaptureVideoArchive.captureBudget, sampleInterval: 0))
        taskID = capture.taskID; self.capture = capture
        let archive = try CaptureVideoArchive(taskDirectory: store.taskDirectory(taskID))
        self.archive = archive
        capture.prepareToFinish = { [weak archive] in try? archive?.finish() }
        let queue = DispatchQueue(label: "ScrollStitch.capture-limits", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        deadline = timer; timer.resume()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in self?.requestStop(.memoryPressure) }
        self.pressure = pressure; pressure.resume()
    }

    public func consume(_ owned:NativeVideoSample) {
        let sample=owned.sample,orientation=owned.orientation
        let acceptedUptime=max(owned.acceptedUptime,began)
        lock.lock(); defer { lock.unlock() }
        guard let capture,!closing else { return }
        autoreleasepool {
            do {
                guard let pixel = CMSampleBufferGetImageBuffer(sample), (1...8).contains(orientation),
                      let exif = CGImagePropertyOrientation(rawValue: UInt32(orientation)) else {
                    throw ScrollStitchError.corruptData
                }
                let image = CIImage(cvPixelBuffer: pixel).oriented(exif)
                guard image.extent.height >= image.extent.width,
                      geometry == nil || geometry == image.extent.size,
                      self.orientation == nil || self.orientation == orientation else {
                    finish(.sizeChanged); return
                }
                geometry = image.extent.size; self.orientation = orientation
                if let archive {
                    guard try archive.append(sample, orientation: orientation,
                        availableBytes: CaptureVideoArchive.captureBudget - capture.storedBytes - archive.committedBytes,ownedBuffer:true) else {
                        finish(.storageBudget); return
                    }
                    capture.externalStoredBytes = archive.reservedBytes
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard motion.shouldObserve(at: time) else { return }
                let w = 80, h = 160
                let reduced = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: Double(w) / image.extent.width, y: Double(h) / image.extent.height))
                var luma = [UInt8](repeating: 0, count: w * h)
                luma.withUnsafeMutableBytes { bytes in
                    context.render(reduced, toBitmap: bytes.baseAddress!, rowBytes: w,
                        bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
                }
                guard !pngPending,capture.acceptedFrames<199,motion.select(luma,width:w,height:h,at:time) else { return }
                pngPending=true
                pngQueue.async { [self,owned] in
                    defer { withExtendedLifetime(owned) {} }
                    autoreleasepool {
                    do {
                    // PNG encoding runs outside the state lock; video ingestion keeps flowing.
                    let encoded:OwnedVideoFrame = try {


                    guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8,
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw ScrollStitchError.corruptData }
                    let data = NSMutableData()
                    guard let encoder = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                        throw ScrollStitchError.storageFailure
                    }
                    CGImageDestinationAddImage(encoder, cg, nil)
                    guard CGImageDestinationFinalize(encoder) else { throw ScrollStitchError.storageFailure }
                    return try OwnedVideoFrame(png: data as Data, size: PixelSize(width: cg.width, height: cg.height),
                        pts: time, orientation: orientation)
                    }()
                    lock.lock()
                    defer { pngPending=false;lock.unlock() }
                    guard let capture=self.capture else { return }
                    let result=try capture.process(.video,uptime:acceptedUptime) { encoded }
                    let first=committedFrames==0
                    committedFrames=capture.acceptedFrames
                    if first,committedFrames>0 { onFirstCommittedFrame?() }
                    if case .stopped(let reason)=result { finish(reason) }
                    } catch {
                        lock.lock();pngPending=false;lock.unlock()
                        diagnostics?.record("pngWriteFailed",error:error);finish(.writeFailure)
                    }
                    }
                }
            } catch { diagnostics?.record("frameWriteFailed", error: error); finish(.writeFailure) }
        }
    }

    public func recordDroppedSamples(count: Int, lower: Double, upper: Double) {
        lock.lock(); defer { lock.unlock() }
        archive?.recordDroppedSamples(count: count, lower: lower, upper: upper)
    }

    private func tick() {
        if ProcessInfo.processInfo.systemUptime-began>=120 { requestStop(.timeBudget) }
    }

    private func requestStop(_ reason:CaptureEndReason) {
        if let onStopRequested {onStopRequested(reason)} else {finish(reason)}
    }
    public func finish(_ reason:CaptureEndReason,completion:@escaping @Sendable ()->Void = {}) {
        lock.lock()
        guard capture != nil else { lock.unlock();completion();return }
        completions.append(completion)
        guard !closing else { lock.unlock();return }
        closing=true
        deadline?.cancel();deadline=nil;pressure?.cancel();pressure=nil
        lock.unlock()
        // Ordered after the accepted PNG job. No end marker precedes its durable write.
        pngQueue.async { [self] in
            lock.lock()
            var finalReason=reason
            do { try archive?.finish();committedVideo=(archive?.committedBytes ?? 0)>0 } catch { diagnostics?.record("archiveFinishFailed",error:error);finalReason = .writeFailure }
            committedFrames=capture?.acceptedFrames ?? committedFrames
            do { try capture?.finish(finalReason) } catch { diagnostics?.record("captureFinishFailed",error:error);finalReason = .writeFailure }
            capture=nil;archive=nil;context.clearCaches()
            let callbacks=completions;completions=[]
            lock.unlock()
            onStop(finalReason)
            for callback in callbacks { callback() }
        }
    }

    deinit { deadline?.cancel(); pressure?.cancel() }
}
