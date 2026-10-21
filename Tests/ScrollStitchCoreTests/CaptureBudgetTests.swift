import CaptureTestSupport
import XCTest
import CoreGraphics
import ImageIO
@testable import ScrollStitchCore

final class CaptureBudgetTests: XCTestCase {
    private func store() throws -> TaskStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try TaskStore(root: root)
    }
    private func frame(color: CGFloat = 1, pts: Double = 1, orientation: Int = 1) throws -> OwnedVideoFrame {
        let context = try XCTUnwrap(CGContext(data:nil,width:10,height:20,bitsPerComponent:8,bytesPerRow:40,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:color,green:0,blue:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:10,height:20))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try OwnedVideoFrame(png:data as Data,size:PixelSize(width:10,height:20),pts:pts,orientation:orientation)
    }
    func testSamplingOccursBeforeEncodingAndOnlyExactDuplicatesAreDropped() throws {
        let store = try store(), session = try CaptureSession(store:store,uptime:0)
        _ = try session.process(.video,uptime:0) { try frame() }
        XCTAssertEqual(try session.process(.video,uptime:0.1) { XCTFail("must not encode"); throw ScrollStitchError.corruptData },.sampledOut)
        XCTAssertEqual(try session.process(.video,uptime:1) { try frame(pts:2) },.duplicate)
        _ = try session.process(.video,uptime:2) { try frame(color:0.8,pts:3) }
        XCTAssertEqual(session.acceptedFrames,2)
        try session.finish(.userStopped)
        XCTAssertEqual(try store.reconcileCapture(taskID:session.taskID).frames.count,2)
    }
    func testTimeLimitEndsEvenWithoutVideoSamples() throws {
        let store = try store(), session = try CaptureSession(store:store,uptime:10)
        XCTAssertNil(try session.tick(uptime:129.99))
        XCTAssertEqual(try session.tick(uptime:130),.timeBudget)
        let result = try store.reconcileCapture(taskID:session.taskID)
        XCTAssertEqual(result.endReason,.timeBudget); XCTAssertTrue(result.frames.isEmpty)
    }
    func testFrameAndDiskLimitsPreserveCommittedPrefix() throws {
        let store = try store()
        let session = try CaptureSession(store:store,uptime:0,limits:CaptureLimits(frames:2,sampleInterval:0))
        _ = try session.process(.video,uptime:0) { try frame() }
        XCTAssertEqual(try session.process(.video,uptime:1) { try frame(color:0.5,pts:2) },.stopped(.frameBudget))
        XCTAssertEqual(try store.reconcileCapture(taskID:session.taskID).frames.count,2)
        let other = try self.store(), disk = try CaptureSession(store:other,uptime:0,limits:CaptureLimits(bytes:1))
        XCTAssertEqual(try disk.process(.video,uptime:0) { try frame() },.stopped(.storageBudget))
        XCTAssertTrue(try other.reconcileCapture(taskID:disk.taskID).frames.isEmpty)
    }
    func testOrientationChangeAndWriteFailureDoNotLoseOriginalFrame() throws {
        let store = try store(), session = try CaptureSession(store:store,uptime:0)
        _ = try session.process(.video,uptime:0) { try frame() }
        XCTAssertEqual(try session.process(.video,uptime:1) { try frame(pts:2,orientation:3) },.stopped(.sizeChanged))
        XCTAssertEqual(try store.reconcileCapture(taskID:session.taskID).frames.count,1)
        let other = try self.store(), failing = try CaptureSession(store:other,uptime:0)
        _ = try failing.process(.video,uptime:0) { try frame() }
        XCTAssertThrowsError(try failing.process(.video,uptime:1) { throw ScrollStitchError.storageFailure })
        let snapshot = try other.reconcileCapture(taskID:failing.taskID)
        XCTAssertEqual(snapshot.frames.count,1); XCTAssertEqual(snapshot.endReason,.writeFailure)
    }
    func testSystemFinishPreservesFramesWithoutAttributingUserIntentOrRenewingTTL() throws {
        let store = try store(), started = Date(timeIntervalSince1970:1000)
        let session = try CaptureSession(store:store,now:started,uptime:0)
        _ = try session.process(.video,uptime:0) { try frame() }
        let before = try store.captureSnapshot(taskID:session.taskID)
        try session.finishFromSystem()
        let recovered = try store.reconcileCapture(taskID:session.taskID)
        XCTAssertEqual(recovered.phase,.interrupted)
        XCTAssertEqual(recovered.endReason,.unknown)
        XCTAssertEqual(recovered.frames.map(\.id),before.frames.map(\.id))
        XCTAssertEqual(recovered.frames.map(\.asset.sha256),before.frames.map(\.asset.sha256))
        XCTAssertEqual(try store.current()?.lastInteractionAt,started)
        // Late/duplicate terminal callbacks cannot rewrite the retained reason or renew TTL.
        try session.finishFromSystem()
        try session.finish(.userStopped)
        let after = try store.reconcileCapture(taskID:session.taskID)
        XCTAssertEqual(after.sequence,recovered.sequence)
        XCTAssertEqual(after.endReason,.unknown)
        XCTAssertEqual(try store.current()?.lastInteractionAt,started)
    }
    func testSystemFinishCannotReplaceEarlierBudgetReason() throws {
        let store = try store(), session = try CaptureSession(store:store,uptime:0,limits:CaptureLimits(frames:1))
        XCTAssertEqual(try session.process(.video,uptime:0) { try frame() },.stopped(.frameBudget))
        try session.finishFromSystem()
        let recovered = try store.reconcileCapture(taskID:session.taskID)
        XCTAssertEqual(recovered.phase,.interrupted)
        XCTAssertEqual(recovered.endReason,.frameBudget)
        XCTAssertEqual(recovered.frames.count,1)
    }
    func testSystemFinishWithoutFramesDoesNotClaimSuccess() throws {
        let store = try store(), session = try CaptureSession(store:store)
        try session.finishFromSystem()
        let recovered = try store.reconcileCapture(taskID:session.taskID)
        XCTAssertEqual(recovered.phase,.interrupted)
        XCTAssertEqual(recovered.endReason,.unknown)
        XCTAssertTrue(recovered.frames.isEmpty)
    }
    func testMemoryPressureStopPreservesPrefixAndCannotResumeOrRenewTTL() throws {
        let store = try store(), started = Date(timeIntervalSince1970:1000)
        let session = try CaptureSession(store:store,now:started,uptime:0)
        _ = try session.process(.video,uptime:0) { try frame() }
        let before = try store.captureSnapshot(taskID:session.taskID)
        let original = try Data(contentsOf:store.assetURL(before.frames[0].asset,taskID:session.taskID))
        try session.finish(.memoryPressure)
        try session.finishFromSystem()
        let reopened = try TaskStore(root:store.root)
        let recovered = try reopened.reconcileCapture(taskID:session.taskID)
        XCTAssertEqual(recovered.endReason,.memoryPressure)
        XCTAssertEqual(recovered.phase,.interrupted)
        XCTAssertEqual(recovered.frames,before.frames)
        XCTAssertEqual(try Data(contentsOf:reopened.assetURL(recovered.frames[0].asset,taskID:session.taskID)),original)
        XCTAssertEqual(try reopened.current()?.lastInteractionAt,started)
        XCTAssertThrowsError(try session.process(.video,uptime:1) {
            XCTFail("No encoding after memory stop"); return try frame()
        })
        XCTAssertThrowsError(try CaptureSession(store:reopened))
        // Owner has been released, while the preserved current task still rejects new capture.
        XCTAssertTrue(try reopened.cleanup(taskID:session.taskID,explicit:true))
    }
}
