import XCTest
import ImageIO
import CoreGraphics
@testable import ScrollStitchCore

private actor FakePhotoWriter: PhotoLibraryWriting {
    var permission: PhotoAuthorization
    let requested: PhotoAuthorization
    var requests=0, writes=0
    var writtenDigest: String?
    var pause=false
    var continuation: CheckedContinuation<Void,Never>?
    init(_ permission: PhotoAuthorization = .authorized, requested: PhotoAuthorization = .authorized, pause: Bool = false) {
        self.permission=permission; self.requested=requested; self.pause=pause
    }
    func authorization() -> PhotoAuthorization { permission }
    func requestAddOnly() -> PhotoAuthorization { requests+=1; permission=requested; return requested }
    func write(fileURL: URL) async throws {
        writes+=1; writtenDigest=try TaskStore.digest(url:fileURL)
        if pause { await withCheckedContinuation { continuation=$0 } }
    }
    func resume() { continuation?.resume(); continuation=nil }
    func counts() -> (Int,Int,String?) { (requests,writes,writtenDigest) }
}

final class ResultExportTests: XCTestCase {
    private func fixture(fault: (@Sendable (StoreFaultPoint) throws -> Void)? = nil) throws -> (TaskStore,ResultManifest) {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let store=try TaskStore(root:root,fault:fault), task=try store.createCollage()
        let url=try store.taskDirectory(task.taskID).appendingPathComponent("exports/output.png")
        let ctx=try XCTUnwrap(CGContext(data:nil,width:20,height:30,bitsPerComponent:8,bytesPerRow:80,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red:0.2,green:0.7,blue:0.5,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:20,height:30))
        let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(writer,try XCTUnwrap(ctx.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let data=try Data(contentsOf:url)
        let result=try ResultManifest(taskID:task.taskID,revision:0,selectionFingerprint:TaskStore.digest(data:Data("selection".utf8)),
            path:AssetPath("exports/output.png"),format:"png",size:PixelSize(width:20,height:30),sizeBytes:data.count,sha256:TaskStore.digest(data:data))
        try store.publishResult(result)
        return (store,result)
    }
    func testResultRestoresOnlyMatchingRevisionSelectionAndBytes() throws {
        let (store,result)=try fixture()
        XCTAssertEqual(try store.currentResult(taskID:result.taskID,selectionFingerprint:result.selectionFingerprint),result)
        XCTAssertNil(try store.currentResult(taskID:result.taskID,selectionFingerprint:String(repeating:"a",count:64)))
        var edit=try store.editSnapshot(taskID:result.taskID);edit.spacingPx=8
        _=try store.commitEdit(edit,expectedRevision:0)
        XCTAssertNil(try store.currentResult(taskID:result.taskID,selectionFingerprint:result.selectionFingerprint))
        XCTAssertThrowsError(try store.openResult(taskID:result.taskID,resultID:result.id))
        XCTAssertNotNil(try store.current())
    }
    @MainActor func testPreviewWaitsForConcurrentThumbnailWithoutChangingSavedBytes() async throws {
        let (store,result)=try fixture()
        var thumbnail:ResultAccess?=try store.openResult(taskID:result.taskID,resultID:result.id)
        XCTAssertThrowsError(try store.openResult(taskID:result.taskID,resultID:result.id)) {
            XCTAssertEqual($0 as? ScrollStitchError,.resourceBusy)
        }
        let preview=Task { try await store.openResultForPreview(taskID:result.taskID,resultID:result.id) }
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertNotNil(thumbnail)
        thumbnail=nil
        let access=try await preview.value
        XCTAssertEqual(try TaskStore.digest(url:access.url),result.sha256)
        XCTAssertNil(try store.photoSaveRecord(access))
        XCTAssertFalse(try store.cleanup(taskID:result.taskID,explicit:true))
        withExtendedLifetime(access) {}
    }
    @MainActor func testPreviewBusyWaitHasDeadlineAndHonorsCancellation() async throws {
        let (store,result)=try fixture()
        let owner=try store.openResult(taskID:result.taskID,resultID:result.id)
        do {
            _=try await store.openResultForPreview(taskID:result.taskID,resultID:result.id,wait:.milliseconds(30))
            XCTFail("A held exclusive owner must not be bypassed")
        } catch { XCTAssertEqual(error as? ScrollStitchError,.resourceBusy) }
        let pending=Task {try await store.openResultForPreview(taskID:result.taskID,resultID:result.id)}
        pending.cancel()
        do { _=try await pending.value;XCTFail("Cancelled preview should not acquire files") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try TaskStore.digest(url:owner.url),result.sha256)
        withExtendedLifetime(owner) {}
    }
    func testPreviewDoesNotHideCorruptResultAsTemporaryContention() async throws {
        let (store,result)=try fixture()
        let url=try result.path.resolved(in:store.taskDirectory(result.taskID))
        try Data([0,1,2]).write(to:url)
        do {
            _=try await store.openResultForPreview(taskID:result.taskID,resultID:result.id)
            XCTFail("Corrupt results must remain unreadable")
        } catch { XCTAssertNotEqual(error as? ScrollStitchError,.resourceBusy) }
        XCTAssertNotNil(try store.current())
    }
    func testCorruptResultDoesNotDeleteSourcesOrCurrentTask() throws {
        let (store,result)=try fixture(), dir=try store.taskDirectory(result.taskID)
        let original=dir.appendingPathComponent("assets/sentinel.bin")
        try Data("untouched".utf8).write(to:original)
        try Data([0,1,2]).write(to:result.path.resolved(in:dir))
        XCTAssertNil(try store.currentResult(taskID:result.taskID,selectionFingerprint:result.selectionFingerprint))
        XCTAssertEqual(try String(contentsOf:original,encoding:.utf8),"untouched")
        XCTAssertEqual(try store.current()?.taskID,result.taskID)
        XCTAssertThrowsError(try AssetPath("exports/../../private.png"))
    }
    func testLeaseProtectsFileAndOldCompletionCannotOverwriteNewSave() throws {
        let (store,result)=try fixture()
        var access:ResultAccess?=try store.openResult(taskID:result.taskID,resultID:result.id)
        let a=try store.beginPhotoSave(access!)
        XCTAssertThrowsError(try store.beginPhotoSave(access!))
        try store.finishPhotoSave(access!,operationID:a.operationID,success:true)
        XCTAssertThrowsError(try store.beginPhotoSave(access!))
        let b=try store.beginPhotoSave(access!,confirmedRepeat:true)
        XCTAssertNotEqual(a.operationID,b.operationID)
        XCTAssertThrowsError(try store.finishPhotoSave(access!,operationID:a.operationID,success:true))
        XCTAssertFalse(try store.cleanup(taskID:result.taskID,explicit:true))
        XCTAssertTrue(FileManager.default.fileExists(atPath:access!.url.path))
        try store.finishPhotoSave(access!,operationID:b.operationID,success:true)
        access=nil
        XCTAssertTrue(try store.cleanup(taskID:result.taskID,explicit:true))
    }
    @MainActor func testPermissionOnlyRequestedOnSaveAndDeniedNeverWrites() async throws {
        let (store,result)=try fixture(), writer=FakePhotoWriter(.notDetermined,requested:.denied)
        let c=PhotoExportController(writer:writer);c.restore(nil)
        let before=await writer.counts();XCTAssertEqual(before.0,0);XCTAssertEqual(before.1,0)
        await c.save(store:store,result:result)
        let after=await writer.counts();XCTAssertEqual(after.0,1);XCTAssertEqual(after.1,0)
        XCTAssertEqual(c.state,.denied)
        let access=try store.openResult(taskID:result.taskID,resultID:result.id)
        XCTAssertNil(try store.photoSaveRecord(access)) // Still shareable without Photos permission.
    }
    @MainActor func testDoubleTapWritesOriginalOnceAndWaitsForCallback() async throws {
        let (store,result)=try fixture(), writer=FakePhotoWriter(pause:true)
        let c=PhotoExportController(writer:writer)
        let first=Task { await c.save(store:store,result:result) }
        for _ in 0..<200 {
            if await writer.counts().1 == 1 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertEqual(c.state,.writing)
        await c.save(store:store,result:result)
        let during=await writer.counts();XCTAssertEqual(during.1,1);XCTAssertEqual(during.2,result.sha256)
        XCTAssertThrowsError(try store.openResult(taskID:result.taskID,resultID:result.id))
        await writer.resume();await first.value
        XCTAssertEqual(c.state,.saved)
        await c.save(store:store,result:result)
        let after=await writer.counts();XCTAssertEqual(after.1,1)
    }
    @MainActor func testBackgroundSaveDefersFirstPermissionPromptWithoutBeginningWrite() async throws {
        let (store,result)=try fixture(),writer=FakePhotoWriter(.notDetermined)
        let controller=PhotoExportController(writer:writer)
        let saved=await controller.saveAll(store:store,results:[result],requestPermission:false)
        XCTAssertEqual(saved,0);XCTAssertEqual(controller.state,.denied)
        let counts=await writer.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0)
        let access=try store.openResult(taskID:result.taskID,resultID:result.id)
        XCTAssertNil(try store.photoSaveRecord(access))
    }
    @MainActor func testUnconfirmedWriteSurvivesRestartAndNeverRetriesAutomatically() async throws {
        let (store,result)=try fixture()
        var access:ResultAccess?=try store.openResult(taskID:result.taskID,resultID:result.id)
        let intent=try store.beginPhotoSave(access!);access=nil
        let writer=FakePhotoWriter(), c=PhotoExportController(writer:writer)
        c.restore(intent);XCTAssertEqual(c.state,.unknown)
        await c.save(store:store,result:result)
        let noWrite=await writer.counts();XCTAssertEqual(noWrite.1,0);XCTAssertEqual(c.state,.unknown)
        await c.save(store:store,result:result,confirmedRepeat:true)
        let repeatWrite=await writer.counts();XCTAssertEqual(repeatWrite.1,1);XCTAssertEqual(c.state,.saved)
    }
    @MainActor func testSuccessfulSystemWriteWithFailedLocalCompletionRemainsUnknown() async throws {
        let (store,result)=try fixture { if $0 == .beforePhotoSaveCompletion { throw ScrollStitchError.storageFailure } }
        let writer=FakePhotoWriter(), c=PhotoExportController(writer:writer)
        await c.save(store:store,result:result)
        XCTAssertEqual(c.state,.unknown)
        await c.save(store:store,result:result)
        let counts=await writer.counts();XCTAssertEqual(counts.1,1)
        let access=try store.openResult(taskID:result.taskID,resultID:result.id)
        XCTAssertEqual(try store.photoSaveRecord(access)?.phase,.writing)
    }
    @MainActor func testIntentWriteFailureNeverCallsSystemWriter() async throws {
        let (store,result)=try fixture { if $0 == .beforePhotoSaveIntent { throw ScrollStitchError.storageFailure } }
        let writer=FakePhotoWriter(), c=PhotoExportController(writer:writer)
        await c.save(store:store,result:result)
        let counts=await writer.counts();XCTAssertEqual(counts.1,0);XCTAssertEqual(c.state,.failed)
    }
    func testM2UndoDoesNotResurrectOldResultOrRewindUncertainPhotoWrite() throws {
        let (store,result)=try fixture(), directory=try store.taskDirectory(result.taskID)
        var access:ResultAccess?=try store.openResult(taskID:result.taskID,resultID:result.id)
        _=try store.beginPhotoSave(try XCTUnwrap(access))
        access=nil
        let ledger=directory.appendingPathComponent("photo-save-v1.json"), before=try Data(contentsOf:ledger)
        var edit=try store.applyEdit(taskID:result.taskID,expectedRevision:0,command:.options(spacing:8,background:nil,width:nil))
        edit=try store.undoEdit(taskID:result.taskID,expectedRevision:edit.revision)
        XCTAssertEqual(edit.spacingPx,0); XCTAssertEqual(edit.revision,2)
        XCTAssertEqual(try Data(contentsOf:ledger),before)
        XCTAssertNil(try store.currentResult(taskID:result.taskID,selectionFingerprint:result.selectionFingerprint))
        XCTAssertThrowsError(try store.openResult(taskID:result.taskID,resultID:result.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath:try result.path.resolved(in:directory).path))
    }

}
