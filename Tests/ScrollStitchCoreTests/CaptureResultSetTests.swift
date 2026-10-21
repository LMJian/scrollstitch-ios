import XCTest
import CoreGraphics
import ImageIO
@testable import ScrollStitchCore

private actor BatchPhotoWriter:PhotoLibraryWriting {
    var writes=0
    func authorization() async -> PhotoAuthorization {.authorized}
    func requestAddOnly() async -> PhotoAuthorization {.authorized}
    func write(fileURL:URL) async throws {writes+=1}
    func count() -> Int {writes}
}
final class CaptureResultSetTests:XCTestCase {
    private func fixture() throws -> (TaskStore,CaptureResultSet) {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let store=try TaskStore(root:root)
        let (task,owner)=try store.beginCapture()
        try store.finishCapture(taskID:task.taskID,owner:owner,reason:.userStopped)
        let capture=try store.captureSnapshot(taskID:task.taskID,verifyFiles:false)
        let identity=String(repeating:"a",count:64),recipe=String(repeating:"b",count:64)
        var pages=[CaptureResultPage]()
        for index in 0..<2 {
            let url=try store.taskDirectory(task.taskID).appendingPathComponent("exports/page-\(index).png")
            let context=try XCTUnwrap(CGContext(data:nil,width:20,height:30,bitsPerComponent:8,bytesPerRow:80,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red:CGFloat(index),green:0.3,blue:0.6,alpha:1));context.fill(CGRect(x:0,y:0,width:20,height:30))
            let writer=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(writer,try XCTUnwrap(context.makeImage()),nil);XCTAssertTrue(CGImageDestinationFinalize(writer))
            let data=try Data(contentsOf:url)
            let result=try ResultManifest(taskID:task.taskID,revision:capture.sequence,
                selectionFingerprint:TaskStore.digest(data:Data("page-\(index)".utf8)),path:AssetPath("exports/page-\(index).png"),
                format:"png",size:PixelSize(width:20,height:30),sizeBytes:data.count,sha256:TaskStore.digest(data:data))
            pages.append(CaptureResultPage(sourceIdentity:identity,recipe:recipe,document:0,page:index,result:result))
        }
        return (store,CaptureResultSet(taskID:task.taskID,revision:capture.sequence,sourceIdentity:identity,recipe:recipe,
            selectionFingerprint:identity,status:.complete,pages:pages,gaps:[]))
    }
    func testEveryPageRestoresAndHasIndependentPhotoIntent() throws {
        let (store,set)=try fixture();try store.publishCaptureResultSet(set)
        XCTAssertEqual(try store.captureResultSet(taskID:set.taskID,selectionFingerprint:set.selectionFingerprint),set)
        XCTAssertEqual(try store.currentResult(taskID:set.taskID,selectionFingerprint:set.selectionFingerprint),set.pages[0].result)
        let access=try store.openResults(taskID:set.taskID,resultIDs:set.pages.map{$0.result.id})
        let first=access[0],second=access[1]
        let intent=try store.beginPhotoSave(first)
        XCTAssertThrowsError(try store.beginPhotoSave(first))
        XCTAssertNil(try store.photoSaveRecord(second))
        try store.finishPhotoSave(first,operationID:intent.operationID,success:true)
        XCTAssertEqual(try store.photoSaveRecord(first)?.phase,.saved)
        XCTAssertNotEqual(try store.beginPhotoSave(second).operationID,intent.operationID)
        XCTAssertFalse(try store.cleanup(taskID:set.taskID,explicit:true))
        XCTAssertTrue(FileManager.default.fileExists(atPath:second.url.path))
    }
    func testPublishFailureLeavesPriorCompleteSetReadable() throws {
        let (store,set)=try fixture();try store.publishCaptureResultSet(set)
        let bad=CaptureResultSet(taskID:set.taskID,revision:set.revision+1,sourceIdentity:set.sourceIdentity,
            recipe:set.recipe,selectionFingerprint:set.selectionFingerprint,status:.complete,pages:set.pages,gaps:[])
        XCTAssertThrowsError(try store.publishCaptureResultSet(bad))
        XCTAssertEqual(try store.captureResultSet(taskID:set.taskID,selectionFingerprint:set.selectionFingerprint),set)
        for page in set.pages { XCTAssertNoThrow(try store.openResult(taskID:set.taskID,resultID:page.result.id)) }
    }
    @MainActor func testBatchResumeSkipsSuccessfulPagesAndStopsAtUnknownWrite() async throws {
        let (store,set)=try fixture();try store.publishCaptureResultSet(set)
        do {
            let access=try store.openResult(taskID:set.taskID,resultID:set.pages[0].result.id)
            let intent=try store.beginPhotoSave(access)
            try store.finishPhotoSave(access,operationID:intent.operationID,success:true)
        }
        do {
            let access=try store.openResult(taskID:set.taskID,resultID:set.pages[1].result.id)
            _=try store.beginPhotoSave(access)
        }
        let writer=BatchPhotoWriter(),controller=PhotoExportController(writer:writer)
        let saved=await controller.saveAll(store:store,results:set.pages.map(\.result))
        XCTAssertEqual(saved,1);XCTAssertEqual(controller.state,.unknown)
        let writes=await writer.count();XCTAssertEqual(writes,0)
        XCTAssertFalse(controller.inFlight)
    }
    @MainActor func testCancelledBatchPreservesSavedPageAndContinuesRemainingOnce() async throws {
        let (store,set)=try fixture();try store.publishCaptureResultSet(set)
        let writer=BatchPhotoWriter(),controller=PhotoExportController(writer:writer)
        var done=0
        let saved=await controller.saveAll(store:store,results:set.pages.map(\.result),cancelled:{done==1},progress:{current,_ in done=current})
        XCTAssertEqual(saved,1)
        let completed=await controller.saveAll(store:store,results:set.pages.map(\.result))
        XCTAssertEqual(completed,2)
        let writes=await writer.count();XCTAssertEqual(writes,2)
    }
    func testDisconnectedDocumentsCannotBeLabeledComplete() throws {
        let (_,set)=try fixture()
        let second=CaptureResultPage(sourceIdentity:set.sourceIdentity,recipe:set.recipe,document:1,page:0,result:set.pages[1].result)
        let invalid=CaptureResultSet(taskID:set.taskID,revision:set.revision,sourceIdentity:set.sourceIdentity,recipe:set.recipe,
            selectionFingerprint:set.selectionFingerprint,status:.complete,pages:[set.pages[0],second],gaps:[])
        XCTAssertThrowsError(try invalid.validate())
        let separated=CaptureResultSet(taskID:set.taskID,revision:set.revision,sourceIdentity:set.sourceIdentity,recipe:set.recipe,
            selectionFingerprint:set.selectionFingerprint,status:.separated,pages:[set.pages[0],second],gaps:["未连接"])
        XCTAssertNoThrow(try separated.validate())
    }
}
