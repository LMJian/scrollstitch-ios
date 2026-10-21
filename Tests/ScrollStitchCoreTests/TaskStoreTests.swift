import XCTest
import ImageIO
import CoreGraphics
@testable import ScrollStitchCore

final class TaskStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func png() throws -> Data {
        let c = try XCTUnwrap(CGContext(data:nil,width:20,height:10,bitsPerComponent:8,bytesPerRow:80,
                                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); c.fill(CGRect(x:0,y:0,width:20,height:10))
        let data = NSMutableData()
        let d = try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(d,try XCTUnwrap(c.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(d)); return data as Data
    }
    private func probe(root: URL, operation: String, signal: URL) throws -> Process {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = repo.appendingPathComponent(".build/tests/debug/StoreProbe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process(); process.executableURL = executable
        process.arguments = [root.path,operation,signal.path]
        try process.run(); return process
    }
    func testCollageEditionPreservesExpiredCaptureAndItsVerifiedResult() throws {
        let store = try TaskStore(root:directory()), old = Date(timeIntervalSince1970:100)
        var session: (TaskManifest,FileLease)? = try store.beginCapture(now:old)
        let id = try XCTUnwrap(session).0.taskID, bytes = try png()
        _ = try store.appendFrame(taskID:id,owner:session!.1,png:bytes,size:PixelSize(width:20,height:10),pts:1)
        try store.finishCapture(taskID:id,owner:session!.1,reason:.unknown,now:old)
        session=nil
        let capture = try store.captureSnapshot(taskID:id), dir = try store.taskDirectory(id)
        let output = dir.appendingPathComponent("exports/legacy.png")
        try bytes.write(to:output)
        let result = try ResultManifest(taskID:id,revision:capture.sequence,
            selectionFingerprint:TaskStore.digest(data:Data("legacy selection".utf8)),path:AssetPath("exports/legacy.png"),
            format:"png",size:PixelSize(width:20,height:10),sizeBytes:bytes.count,sha256:TaskStore.digest(data:bytes))
        try store.publishResult(result)
        let files=[store.root.appendingPathComponent("current.json"),dir.appendingPathComponent("capture.json"),
                   dir.appendingPathComponent("result-v1.json"),try capture.frames[0].asset.path.resolved(in:dir),output]
        let before=try files.map { try Data(contentsOf:$0) }
        for _ in 0..<2 {
            let recovered=try WorkspaceRecovery.read(store,captureCreationEnabled:false,now:old.addingTimeInterval(100_000))
            XCTAssertEqual(recovered.manifest?.taskID,id)
            XCTAssertEqual(recovered.capture,capture)
            XCTAssertNil(recovered.edit)
            XCTAssertEqual(try store.currentResult(taskID:id,selectionFingerprint:result.selectionFingerprint),result)
            let access=try store.openResult(taskID:id,resultID:result.id)
            XCTAssertEqual(try Data(contentsOf:access.url),bytes)
        }
        XCTAssertEqual(try files.map { try Data(contentsOf:$0) },before)
        // A corrupt output remains a cache miss; recovery never deletes input or generates a replacement.
        try Data([0,1,2]).write(to:output)
        _=try WorkspaceRecovery.read(store,captureCreationEnabled:false,now:old.addingTimeInterval(200_000))
        XCTAssertNil(try store.currentResult(taskID:id,selectionFingerprint:result.selectionFingerprint))
        XCTAssertEqual(try Data(contentsOf:files[3]),bytes)
        XCTAssertEqual(try store.current()?.taskID,id)
    }
    func testLegacyReadDoesNotReconcileAbandonedCaptureAndCollageExpiryIsUnchanged() throws {
        let store=try TaskStore(root:directory()),old=Date(timeIntervalSince1970:100)
        var session:(TaskManifest,FileLease)?=try store.beginCapture(now:old)
        let id=try XCTUnwrap(session).0.taskID
        session=nil // Simulate an absent writer; this edition must not rewrite capture state.
        let before=try store.captureSnapshot(taskID:id)
        let recovered=try WorkspaceRecovery.read(store,captureCreationEnabled:false,now:old.addingTimeInterval(100_000))
        XCTAssertEqual(recovered.capture,before)
        XCTAssertNil(try store.currentResult(taskID:id,selectionFingerprint:TaskStore.digest(data:Data())))
        XCTAssertTrue(try store.cleanup(taskID:id,explicit:true))
        _=try store.createCollage(now:old)
        XCTAssertNil(try WorkspaceRecovery.read(store,captureCreationEnabled:false,now:old.addingTimeInterval(100_000)).manifest)
    }
    func testPersistedTimesUseUnixMillisecondsAndOnlyExplicitInteractionRenewsTTL() throws {
        let store = try TaskStore(root:directory()), time = Date(timeIntervalSince1970:1_800_000_000.125)
        let task = try store.createCollage(now:time)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:store.root.appendingPathComponent("current.json"))) as? [String:Any])
        XCTAssertEqual(try XCTUnwrap(raw["lastInteractionAt"] as? Double),1_800_000_000_125,accuracy:0.001)
        XCTAssertEqual(try store.current()?.lastInteractionAt,time)
        let later = time.addingTimeInterval(60)
        try store.recordInteraction(taskID:task.taskID,now:later)
        _ = try store.editSnapshot(taskID:task.taskID)
        XCTAssertEqual(try store.current()?.lastInteractionAt,later)
        XCTAssertFalse(try store.cleanup(taskID:task.taskID,explicit:false,now:time.addingTimeInterval(86_400)))
        XCTAssertTrue(try store.cleanup(taskID:task.taskID,explicit:false,now:later.addingTimeInterval(86_400)))
    }
    func testTwoRealProcessesCannotOverwriteCurrentTask() throws {
        let root = try directory(), signal = root.appendingPathComponent("go")
        let a = try probe(root:root,operation:"create",signal:signal)
        let b = try probe(root:root,operation:"create",signal:signal)
        try Data().write(to:signal)
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual([a.terminationStatus,b.terminationStatus].sorted(),[0,4])
        XCTAssertEqual(try TaskStore(root:root).current()?.kind,.collage)
    }
    func testCrashesAtEachCommitBoundaryRecoverOnlyCommittedFrames() throws {
        for operation in ["crash-write","crash-rename","crash-before","crash-after"] {
            let root = try directory(), fixture = root.appendingPathComponent("fixture.png")
            try png().write(to:fixture)
            let process = try probe(root:root,operation:operation,signal:fixture)
            process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,73)
            let store = try TaskStore(root:root), task = try XCTUnwrap(store.current())
            let recovered = try store.reconcileCapture(taskID:task.taskID)
            XCTAssertEqual(recovered.phase,.interrupted); XCTAssertEqual(recovered.endReason,.ownerLost)
            XCTAssertEqual(recovered.frames.count,operation == "crash-after" ? 1 : 0)
            let dir = try store.taskDirectory(task.taskID)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("temporary").path).isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.appendingPathComponent("assets").path).count,recovered.frames.count)
            XCTAssertTrue(FileManager.default.fileExists(atPath:fixture.path))
        }
    }
    func testLiveOwnerBlocksExpiryAndCannotBeInferredDeadFromTime() throws {
        let store = try TaskStore(root:directory()), old = Date(timeIntervalSince1970:100)
        var session: (TaskManifest,FileLease)? = try store.beginCapture(now:old)
        let id = try XCTUnwrap(session).0.taskID
        _ = try store.appendFrame(taskID:id,owner:session!.1,png:png(),size:PixelSize(width:20,height:10),pts:1)
        XCTAssertEqual(try store.reconcileCapture(taskID:id).phase,.reconciling)
        XCTAssertFalse(try store.cleanup(taskID:id,explicit:false,now:old.addingTimeInterval(100_000)))
        XCTAssertThrowsError(try store.createCollage())
        try store.finishCapture(taskID:id,owner:session!.1,reason:.userStopped)
        XCTAssertEqual(try store.reconcileCapture(taskID:id).phase,.reconciling)
        session = nil
        XCTAssertEqual(try store.reconcileCapture(taskID:id).phase,.ended)
        XCTAssertFalse(try store.cleanup(taskID:id,explicit:false,now:old))
        XCTAssertNotNil(try store.current())
        XCTAssertTrue(try store.cleanup(taskID:id,explicit:true,now:old))
        XCTAssertNil(try store.current())
    }
    func testReadDoesNotExtendTTLAndShareLeaseDefersCleanup() throws {
        let store = try TaskStore(root:directory()), now = Date(timeIntervalSince1970:100)
        let task = try store.createCollage(now:now)
        XCTAssertEqual(try store.current()?.lastInteractionAt,now)
        XCTAssertFalse(try store.cleanup(taskID:task.taskID,explicit:false,now:now.addingTimeInterval(86_399)))
        var share: FileLease? = try store.acquireShareLease(taskID:task.taskID)
        XCTAssertNotNil(share)
        XCTAssertFalse(try store.cleanup(taskID:task.taskID,explicit:false,now:now.addingTimeInterval(86_400)))
        share = nil
        XCTAssertTrue(try store.cleanup(taskID:task.taskID,explicit:false,now:now))
    }
    func testEditCASAndSourceCopiesSurviveCleanup() throws {
        let root = try directory(), source = root.appendingPathComponent("original.png")
        try png().write(to:source); let originalDigest = try TaskStore.digest(url:source)
        let store = try TaskStore(root:root), task = try store.createCollage()
        let asset = try store.importAsset(from:source,taskID:task.taskID,size:PixelSize(width:20,height:10))
        var edit = try store.editSnapshot(taskID:task.taskID); edit.assets = [asset]
        let saved = try store.commitEdit(edit,expectedRevision:0)
        XCTAssertEqual(saved.revision,1)
        XCTAssertThrowsError(try store.commitEdit(edit,expectedRevision:0))
        XCTAssertEqual(try store.editSnapshot(taskID:task.taskID),saved)
        XCTAssertTrue(try store.cleanup(taskID:task.taskID,explicit:true))
        XCTAssertEqual(try TaskStore.digest(url:source),originalDigest)
    }
    func testCorruptionCannotProduceAReadySnapshot() throws {
        let store = try TaskStore(root:directory())
        var session: (TaskManifest,FileLease)? = try store.beginCapture()
        let id = session!.0.taskID
        let frame = try store.appendFrame(taskID:id,owner:session!.1,png:png(),size:PixelSize(width:20,height:10),pts:1)
        session = nil
        let file = try frame.asset.path.resolved(in:store.taskDirectory(id))
        try Data("broken".utf8).write(to:file)
        XCTAssertThrowsError(try store.reconcileCapture(taskID:id))
        try Data("{".utf8).write(to:store.root.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try store.current())
        XCTAssertThrowsError(try store.createCollage())
    }
    private func editableStore(now: Date = Date()) throws -> (TaskStore, EditSnapshot) {
        let root=try directory(), source=root.appendingPathComponent("original.png")
        try png().write(to:source)
        let store=try TaskStore(root:root), task=try store.createCollage(now:now)
        var edit=try store.editSnapshot(taskID:task.taskID)
        for _ in 0..<2 { edit.assets.append(try store.importAsset(from:source,taskID:task.taskID,size:PixelSize(width:20,height:10))) }
        return (store,try store.commitEdit(edit,expectedRevision:edit.revision,now:now))
    }
    func testM2CropReorderDeleteUndoSurvivesReopenAndNoOp() throws {
        let (store,initial)=try editableStore(), id=initial.taskID, asset=initial.assets[0]
        let rect=CropRect(x:2,y:1,width:12,height:8)
        var edit=try store.applyEdit(taskID:id,expectedRevision:initial.revision,command:.crop(asset.id,rect))
        let cropped=edit
        edit=try store.applyEdit(taskID:id,expectedRevision:edit.revision,command:.crop(asset.id,rect))
        XCTAssertEqual(edit,cropped)
        edit=try store.applyEdit(taskID:id,expectedRevision:edit.revision,command:.reorder(edit.imports.map(\.id).reversed()))
        XCTAssertEqual(edit.crop(for:asset),rect)
        let beforeDelete=edit
        edit=try store.applyEdit(taskID:id,expectedRevision:edit.revision,command:.remove(edit.imports[1].id))
        XCTAssertEqual(edit.assets.count,1)
        let reopened=try TaskStore(root:store.root)
        _=try reopened.reconcileEdit(taskID:id)
        edit=try reopened.undoEdit(taskID:id,expectedRevision:edit.revision)
        XCTAssertEqual(edit.payload,beforeDelete.payload); XCTAssertNil(edit.undo)
        XCTAssertGreaterThan(edit.revision,beforeDelete.revision)
        XCTAssertThrowsError(try reopened.undoEdit(taskID:id,expectedRevision:edit.revision))
        XCTAssertThrowsError(try reopened.applyEdit(taskID:id,expectedRevision:initial.revision,command:.remove(edit.imports[0].id)))
        XCTAssertEqual(try reopened.editSnapshot(taskID:id),edit)
    }
    func testM2AtomicCommitAndTimestampSurviveManifestFailure() throws {
        let time=Date(timeIntervalSince1970:100), later=time.addingTimeInterval(100_000)
        let (store,initial)=try editableStore(now:time)
        let before=try TaskStore(root:store.root,fault:{ if $0 == .beforeEditReplace { throw ScrollStitchError.storageFailure } })
        XCTAssertThrowsError(try before.applyEdit(taskID:initial.taskID,expectedRevision:initial.revision,command:.options(spacing:8,background:nil,width:nil),now:later))
        XCTAssertEqual(try store.editSnapshot(taskID:initial.taskID),initial)
        let after=try TaskStore(root:store.root,fault:{ if $0 == .afterEditReplace { throw ScrollStitchError.storageFailure } })
        let committed=try after.applyEdit(taskID:initial.taskID,expectedRevision:initial.revision,command:.options(spacing:8,background:nil,width:nil),now:later)
        XCTAssertEqual(committed.spacingPx,8)
        XCTAssertEqual(try store.editSnapshot(taskID:initial.taskID),committed)
        XCTAssertFalse(try store.cleanup(taskID:initial.taskID,explicit:false,now:later.addingTimeInterval(1)))
    }
    func testM2MigrationAndCorruptUndoDoNotLoseCurrentWork() throws {
        let (store,initial)=try editableStore()
        let dir=try store.taskDirectory(initial.taskID)
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("edit-v1-backup.json").path))
        let changed=try store.applyEdit(taskID:initial.taskID,expectedRevision:initial.revision,command:.remove(initial.imports[0].id))
        // Only the undo-only source is damaged. Current work remains readable.
        try Data("broken".utf8).write(to:initial.assets[0].path.resolved(in:dir))
        XCTAssertThrowsError(try store.undoEdit(taskID:initial.taskID,expectedRevision:changed.revision))
        XCTAssertEqual(try store.editSnapshot(taskID:initial.taskID),changed)
        XCTAssertThrowsError(try store.applyEdit(taskID:initial.taskID,expectedRevision:changed.revision,command:.crop(changed.assets[0].id,CropRect(width:0,height:1))))
        XCTAssertEqual(try store.editSnapshot(taskID:initial.taskID),changed)
    }
    func testM2GarbageCollectionHonorsUndoAndShareOwner() throws {
        let (store,initial)=try editableStore(), id=initial.taskID
        let file=try initial.assets[0].path.resolved(in:store.taskDirectory(id))
        var edit=try store.applyEdit(taskID:id,expectedRevision:initial.revision,command:.remove(initial.imports[0].id))
        _=try store.reconcileEdit(taskID:id); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        edit=try store.applyEdit(taskID:id,expectedRevision:edit.revision,command:.options(spacing:8,background:nil,width:nil))
        var owner: FileLease?=try store.acquireShareLease(taskID:id)
        XCTAssertNotNil(owner)
        _=try store.reconcileEdit(taskID:id); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        XCTAssertThrowsError(try store.applyEdit(taskID:id,expectedRevision:edit.revision,command:.options(spacing:16,background:nil,width:nil)))
        owner=nil
        _=try store.reconcileEdit(taskID:id); XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }

    func testM2AppendReservesCapacityDeduplicatesAndUndoesWholeBatch() throws {
        let (store,initial)=try editableStore(), id=initial.taskID
        let selections=[ImportSelection(identifier:"same"),ImportSelection(identifier:"same"),ImportSelection()]
        var access=try store.beginImport(taskID:id,expectedRevision:initial.revision,selections:selections)
        let batchID=try XCTUnwrap(access?.batchID), slots=try XCTUnwrap(access?.slots)
        XCTAssertEqual(slots.count,2)
        let source=store.root.appendingPathComponent("original.png")
        let asset=try store.importAsset(from:source,taskID:id,size:PixelSize(width:20,height:10))
        _=try store.completeImportItem(taskID:id,batchID:batchID,itemID:slots[0].itemID,asset:asset)
        _=try store.finishImport(taskID:id,batchID:batchID)
        XCTAssertThrowsError(try store.completeImportItem(taskID:id,batchID:batchID,itemID:slots[1].itemID,issue:.unavailable))
        let ended=try store.editSnapshot(taskID:id)
        XCTAssertEqual(ended.imports.count,4); XCTAssertEqual(ended.unresolvedImports,1)
        XCTAssertEqual(ended.undo?.payload,initial.payload)
        // The batch object owns the lease until every provider callback lets go.
        XCTAssertThrowsError(try store.undoEdit(taskID:id,expectedRevision:ended.revision))
        access=nil
        let undone=try store.undoEdit(taskID:id,expectedRevision:ended.revision)
        XCTAssertEqual(undone.payload,initial.payload)
        XCTAssertNil(undone.undo)
    }
    func testM2CancelledImportRecoversAndOldTokenCannotOverwriteRetry() throws {
        let (store,initial)=try editableStore(), id=initial.taskID
        var access=try store.beginImport(taskID:id,expectedRevision:initial.revision,selections:[ImportSelection(identifier:"retry")])
        let token=try XCTUnwrap(access?.batchID), slot=try XCTUnwrap(access?.slots.first?.itemID)
        access=nil
        let recovered=try store.reconcileEdit(taskID:id)
        XCTAssertEqual(recovered.imports.last?.issue,.cancelled)
        XCTAssertThrowsError(try store.completeImportItem(taskID:id,batchID:token,itemID:slot,issue:.unavailable))
        var retry=try store.beginImport(taskID:id,expectedRevision:recovered.revision,replacing:slot,selections:[ImportSelection(identifier:"retry")])
        XCTAssertEqual(retry?.slots.first?.itemID,slot)
        _=try store.finishImport(taskID:id,batchID:try XCTUnwrap(retry?.batchID)); retry=nil
        let last=try store.editSnapshot(taskID:id)
        let undone=try store.undoEdit(taskID:id,expectedRevision:last.revision)
        XCTAssertEqual(undone.payload,recovered.payload)
        XCTAssertThrowsError(try store.beginImport(taskID:id,expectedRevision:initial.revision,selections:[ImportSelection()]))
    }
    func testM2ImportLimitsAndInitialFailureLeaveNoEmptyTask() throws {
        let store=try TaskStore(root:directory())
        XCTAssertThrowsError(try store.beginImport(selections:[ImportSelection(identifier:"same"),ImportSelection(identifier:"same")]))
        XCTAssertNil(try store.current())
        let failing=try TaskStore(root:store.root,fault:{ if $0 == .beforeEditReplace { throw ScrollStitchError.storageFailure } })
        XCTAssertThrowsError(try failing.beginImport(selections:[ImportSelection(),ImportSelection()]))
        XCTAssertNil(try store.current())
        var access=try store.beginImport(selections:(0..<20).map { ImportSelection(identifier:"id-\($0)") })
        let id=try XCTUnwrap(access?.taskID), token=try XCTUnwrap(access?.batchID)
        _=try store.finishImport(taskID:id,batchID:token); access=nil
        let edit=try store.editSnapshot(taskID:id)
        XCTAssertNil(try store.beginImport(taskID:id,expectedRevision:edit.revision,selections:[ImportSelection(identifier:"id-0")]))
        XCTAssertEqual(try store.editSnapshot(taskID:id),edit)
        XCTAssertThrowsError(try store.beginImport(taskID:id,expectedRevision:edit.revision,selections:[ImportSelection()]))
        XCTAssertEqual(try store.editSnapshot(taskID:id),edit)
        let empty=try store.undoEdit(taskID:id,expectedRevision:edit.revision)
        XCTAssertTrue(empty.assets.isEmpty); XCTAssertTrue(empty.imports.isEmpty)
    }

    func testM2CropDragRoundsOutwardAndKeepsOnePixel() throws {
        let size=try PixelSize(width:100,height:200), insets=CaptureInsets()
        let left=insets.draggingForCollage(edge:"left",translation:1.9,displayedLength:100,in:size)
        XCTAssertEqual(left.left,1)
        let bottom=insets.draggingForCollage(edge:"bottom",translation:-1.9,displayedLength:200,in:size)
        XCTAssertEqual(bottom.bottom,1)
        let narrow=insets.adjustingForCollage(edge:"left",to:1000,in:size).adjustingForCollage(edge:"top",to:1000,in:size)
        XCTAssertEqual(narrow.left,99); XCTAssertEqual(narrow.top,199)
        XCTAssertEqual(insets.draggingForCollage(edge:"top",translation:.nan,displayedLength:100,in:size),insets)
    }

    func testM2LegacyBytesRemainBackedUpAndUnknownSchemaCannotExpire() throws {
        let root=try directory(), source=root.appendingPathComponent("original.png")
        try png().write(to:source)
        let store=try TaskStore(root:root), task=try store.createCollage(now:Date(timeIntervalSince1970:100))
        let assets=try (0..<2).map { _ in try store.importAsset(from:source,taskID:task.taskID,size:PixelSize(width:20,height:10)) }
        let legacy=EditSnapshot(taskID:task.taskID,assets:assets)
        let bytes=try JSONEncoder().encode(legacy), directory=try store.taskDirectory(task.taskID)
        let editURL=directory.appendingPathComponent("edit.json")
        try bytes.write(to:editURL)
        let read=try store.reconcileEdit(taskID:task.taskID)
        XCTAssertEqual(read.schemaVersion,1); XCTAssertEqual(read.orderedImports.map(\.id),assets.map(\.id))
        XCTAssertEqual(try Data(contentsOf:editURL),bytes)
        let saved=try store.applyEdit(taskID:task.taskID,expectedRevision:0,command:.options(spacing:8,background:nil,width:nil))
        XCTAssertEqual(saved.schemaVersion,2)
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("edit-v1-backup.json")),bytes)
        var raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:editURL)) as? [String:Any])
        raw["schemaVersion"]=99
        try JSONSerialization.data(withJSONObject:raw).write(to:editURL)
        XCTAssertThrowsError(try store.cleanup(taskID:task.taskID,explicit:false,now:Date.distantFuture))
        XCTAssertNotNil(try store.current())
        XCTAssertTrue(FileManager.default.fileExists(atPath:try assets[0].path.resolved(in:directory).path))
        XCTAssertTrue(try store.cleanup(taskID:task.taskID,explicit:true))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
    }

}
