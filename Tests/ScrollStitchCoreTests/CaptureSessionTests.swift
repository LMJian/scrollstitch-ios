import CaptureTestSupport
import XCTest
@testable import ScrollStitchCore

final class CaptureSessionTests: XCTestCase {
    private func store() throws -> TaskStore {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try TaskStore(root: root)
    }
    func testAudioNeverLoadsOrWritesBuffers() throws {
        let store = try store(), session = try CaptureSession(store: store)
        for kind in [CaptureSampleKind.appAudio, .microphoneAudio] {
            let result = try session.process(kind) { XCTFail("Audio loader must not run"); throw ScrollStitchError.corruptData }
            XCTAssertEqual(result, .ignoredAudio)
        }
        XCTAssertTrue(try store.captureSnapshot(taskID: session.taskID).frames.isEmpty)
        try session.finish(.userStopped)
        XCTAssertEqual(try store.reconcileCapture(taskID: session.taskID).phase, .ended)
    }
    func testExistingTaskIsNotOverwrittenAndUnexpectedOwnerLossIsInterrupted() throws {
        let store = try store()
        var session: CaptureSession? = try CaptureSession(store: store)
        let id = try XCTUnwrap(session).taskID
        XCTAssertThrowsError(try CaptureSession(store: store))
        XCTAssertEqual(try store.current()?.taskID, id)
        session = nil
        XCTAssertEqual(try store.reconcileCapture(taskID: id).endReason, .ownerLost)
    }
    func testInvalidVideoRecordsFailureAndReleasesOwner() throws {
        let store = try store(), session = try CaptureSession(store: store)
        XCTAssertThrowsError(try session.process(.video) { throw ScrollStitchError.corruptData })
        let snapshot = try store.reconcileCapture(taskID: session.taskID)
        XCTAssertEqual(snapshot.endReason, .writeFailure)
        XCTAssertTrue(snapshot.frames.isEmpty)
    }
    func testDiagnosticLeaseBlocksCaptureWithoutCreatingATask() throws {
        let store=try store()
        var guards: [FileLease]?=try store.acquireDiagnosticLease()
        XCTAssertEqual(guards?.count,2)
        XCTAssertNil(try store.current())
        XCTAssertThrowsError(try CaptureSession(store:store))
        guards=nil
        let session=try CaptureSession(store:store)
        try session.finishFromSystem()
    }
    func testFailedDiagnosticLeaseDoesNotLeakCaptureLockOrModifyTask() throws {
        let store=try store(), task=try store.createCollage(now:Date(timeIntervalSince1970:100))
        var share: FileLease?=try store.acquireShareLease(taskID:task.taskID)
        XCTAssertNotNil(share)
        XCTAssertThrowsError(try store.acquireDiagnosticLease())
        XCTAssertEqual(try store.current()?.lastInteractionAt,task.lastInteractionAt)
        share=nil
        // A leaked partial lease would leave this pending instead of removing the task.
        XCTAssertTrue(try store.cleanup(taskID:task.taskID,explicit:true))
        XCTAssertNil(try store.current())
    }
}
