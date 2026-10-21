import CaptureTestSupport
import XCTest
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
@testable import ScrollStitchCore

final class NativeVideoSampleTests: XCTestCase {
    private let orientationKey = "native-test-orientation"
    private func sample(format: OSType) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 128, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: CIColor(red: 1, green: 0, blue: 0)), to: pixel,
            bounds: CGRect(x: 0, y: 0, width: 64, height: 128), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel,
            formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 10, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    private func store() throws -> TaskStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try TaskStore(root: root)
    }
    func testBGRAAndBiPlanarFramesWithoutOrientationCommitImageAndVideo() async throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            let source = try sample(format: format)
            let owned = try NativeVideoSample(copying: source, orientationKey: orientationKey, context: CIContext())
            // The caller may recycle the system surface immediately after ingress.
            CIContext().render(CIImage(color:CIColor(red:0,green:0,blue:1)),to:try XCTUnwrap(CMSampleBufferGetImageBuffer(source)))
            XCTAssertTrue(owned.usedDefaultOrientation)
            XCTAssertEqual(owned.orientation, 1)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(try XCTUnwrap(CMSampleBufferGetImageBuffer(owned.sample))), kCVPixelFormatType_32BGRA)
            let storage = try store(), sink = try CaptureSampleSink(store: storage) { _ in }
            sink.consume(owned)
            await withCheckedContinuation { continuation in sink.finish(.userStopped) { continuation.resume() } }
            XCTAssertTrue(sink.hasCommittedFrames)
            let capture = try storage.captureSnapshot(taskID: sink.taskID)
            XCTAssertEqual(capture.frames.count, 1)
            let first=try XCTUnwrap(capture.frames.first)
            XCTAssertEqual(first.asset.size, try PixelSize(width: 64, height: 128))
            let directory = try storage.taskDirectory(sink.taskID)
            let sourceImage = try XCTUnwrap(CGImageSourceCreateWithURL(try first.asset.path.resolved(in: directory) as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceImage, 0, nil))
            let image = CIImage(cgImage: cg)
            var rgba = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 20, y: 30, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            XCTAssertGreaterThan(rgba[0], 220); XCTAssertLessThan(rgba[1], 25); XCTAssertLessThan(rgba[2], 25)
            let index = try JSONDecoder().decode(CaptureVideoIndex.self,
                from: Data(contentsOf: directory.appendingPathComponent("recording/index.json")))
            XCTAssertTrue(index.finished); XCTAssertEqual(index.segments.count, 1)
            let timeline=try JSONDecoder().decode(CaptureTimeline.self,from:Data(contentsOf:directory.appendingPathComponent("recording/timeline-v2.json")))
            XCTAssertNoThrow(try timeline.validate());XCTAssertTrue(timeline.finished)
            XCTAssertEqual(timeline.acceptedSourceSamples.count,1)
            XCTAssertEqual(timeline.segmentHashes,index.segments.map(\.sha256))
            XCTAssertEqual(timeline.acceptedSourceSamples.first?.value,10)
            XCTAssertThrowsError(try storage.retireEmptyCaptureForRetry())
            XCTAssertEqual(try storage.current()?.taskID, sink.taskID)
        }
    }
    func testSharedPoolBoundsOwnershipAndReusesOnlyReleasedSurfaces() throws {
        let pool=NativeVideoBufferPool()
        var buffers=[CVPixelBuffer]()
        for _ in 0..<3 { buffers.append(try pool.acquire(width:64,height:128)) }
        XCTAssertThrowsError(try pool.acquire(width:64,height:128)) { XCTAssertEqual($0 as? ScrollStitchError,.resourceBusy) }
        buffers.removeLast()
        buffers.append(try pool.acquire(width:64,height:128))
        XCTAssertEqual(buffers.count,3)
        XCTAssertThrowsError(try pool.acquire(width:128,height:128))
    }
    func testBufferAttachmentOrientationIsReadAndInvalidValueRejected() throws {
        let source = try sample(format: kCVPixelFormatType_32BGRA)
        CMSetAttachment(source, key: orientationKey as CFString, value: NSNumber(value: 6), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let owned = try NativeVideoSample(copying: source, orientationKey: orientationKey, context: CIContext())
        XCTAssertEqual(owned.orientation, 6); XCTAssertFalse(owned.usedDefaultOrientation)
        CMSetAttachment(source, key: orientationKey as CFString, value: NSNumber(value: 99), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try NativeVideoSample(copying: source, orientationKey: orientationKey, context: CIContext()))
    }
    func testRetryRetainsEmptyEvidenceAndRefusesActiveOrRecoverableVideo() throws {
        let storage = try store(), session = try CaptureSession(store: storage)
        XCTAssertThrowsError(try storage.retireEmptyCaptureForRetry())
        try session.finish(.writeFailure)
        let directory = try storage.taskDirectory(session.taskID)
        let before = try Data(contentsOf: directory.appendingPathComponent("capture.json"))
        let originalManifest = try Data(contentsOf: storage.root.appendingPathComponent("current.json"))
        let unfinished = directory.appendingPathComponent("temporary/recoverable.partial.mov")
        try Data([1,2,3]).write(to: unfinished)
        XCTAssertThrowsError(try storage.retireEmptyCaptureForRetry())
        XCTAssertEqual(try Data(contentsOf: unfinished), Data([1,2,3]))
        try FileManager.default.removeItem(at: unfinished)
        try storage.retireEmptyCaptureForRetry()
        XCTAssertNil(try storage.current())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("capture.json")), before)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("retired-startup.json")), originalManifest)
        let next = try CaptureSession(store: storage)
        XCTAssertNotEqual(next.taskID, session.taskID); try next.finish(.userStopped)
    }
}
