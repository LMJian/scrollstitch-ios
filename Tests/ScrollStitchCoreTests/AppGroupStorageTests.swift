import XCTest
import ImageIO
import CoreGraphics
@testable import ScrollStitchCore

final class AppGroupStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data:nil,width:10,height:20,bitsPerComponent:8,bytesPerRow:40,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:10,height:20))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testNewStoreIsSharedInsideLibraryAndReadDoesNotRenewTTL() throws {
        let group = try directory(), first = try TaskStore.inAppGroup(group)
        let time = Date(timeIntervalSince1970:1_800_000_000)
        let task = try first.createCollage(now:time)
        let second = try TaskStore.inAppGroup(group)
        XCTAssertEqual(second.root.path,group.appendingPathComponent("Library/ScrollStitch").path)
        XCTAssertEqual(try second.current()?.taskID,task.taskID)
        XCTAssertEqual(try second.current()?.lastInteractionAt,time)
        XCTAssertFalse(FileManager.default.fileExists(atPath:group.appendingPathComponent("ScrollStitch").path))
    }
    func testMigrationPreservesCaptureAssetAndSnapshotBytesAndIsIdempotent() throws {
        let group = try directory(), old = try TaskStore(root:group.appendingPathComponent("ScrollStitch"))
        var session: (TaskManifest,FileLease)? = try old.beginCapture()
        let id = session!.0.taskID
        let frame = try old.appendFrame(taskID:id,owner:session!.1,png:png(),size:PixelSize(width:10,height:20),pts:1)
        try old.finishCapture(taskID:id,owner:session!.1,reason:.paused)
        session = nil
        let beforeCapture = try Data(contentsOf:old.taskDirectory(id).appendingPathComponent("capture.json"))
        let beforeManifest = try Data(contentsOf:old.root.appendingPathComponent("current.json"))
        let migrated = try TaskStore.inAppGroup(group)
        XCTAssertEqual(try Data(contentsOf:migrated.taskDirectory(id).appendingPathComponent("capture.json")),beforeCapture)
        XCTAssertEqual(try Data(contentsOf:migrated.root.appendingPathComponent("current.json")),beforeManifest)
        XCTAssertEqual(try TaskStore.digest(url:frame.asset.path.resolved(in:migrated.taskDirectory(id))),frame.asset.sha256)
        XCTAssertEqual(try migrated.reconcileCapture(taskID:id).endReason,.paused)
        XCTAssertEqual(try migrated.reconcileCapture(taskID:id).frames.count,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:old.root.path))
        XCTAssertEqual(try TaskStore.inAppGroup(group).current()?.taskID,id)
    }
    func testMigrationWaitsForCaptureAndShareOwnersWithoutMovingData() throws {
        let group = try directory(), old = try TaskStore(root:group.appendingPathComponent("ScrollStitch"))
        var session: (TaskManifest,FileLease)? = try old.beginCapture()
        let id = session!.0.taskID
        XCTAssertThrowsError(try TaskStore.inAppGroup(group)) { XCTAssertEqual($0 as? ScrollStitchError,.resourceBusy) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:old.root.path))
        try old.finishCapture(taskID:id,owner:session!.1,reason:.userStopped)
        session = nil
        var share: FileLease? = try old.acquireShareLease(taskID:id)
        XCTAssertNotNil(share)
        XCTAssertThrowsError(try TaskStore.inAppGroup(group)) { XCTAssertEqual($0 as? ScrollStitchError,.resourceBusy) }
        XCTAssertEqual(try old.current()?.taskID,id)
        share = nil
        XCTAssertEqual(try TaskStore.inAppGroup(group).current()?.taskID,id)
    }
    func testConflictingStoresAreBothPreserved() throws {
        let group = try directory(), old = try TaskStore(root:group.appendingPathComponent("ScrollStitch"))
        let first = try old.createCollage()
        let newer = try TaskStore(root:group.appendingPathComponent("Library/ScrollStitch"))
        let second = try newer.createCollage()
        XCTAssertThrowsError(try TaskStore.inAppGroup(group)) { XCTAssertEqual($0 as? ScrollStitchError,.existingTask) }
        XCTAssertEqual(try old.current()?.taskID,first.taskID)
        XCTAssertEqual(try newer.current()?.taskID,second.taskID)
    }
    func testMigrationRejectsSymlinkedLegacyStore() throws {
        let group = try directory(), outside = try directory()
        try FileManager.default.createSymbolicLink(at:group.appendingPathComponent("ScrollStitch"),withDestinationURL:outside)
        XCTAssertThrowsError(try TaskStore.inAppGroup(group)) { XCTAssertEqual($0 as? ScrollStitchError,.invalidPath) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
    }
}
