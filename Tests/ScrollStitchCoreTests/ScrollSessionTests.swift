import XCTest
@testable import ScrollStitchCore

final class ScrollSessionTests:XCTestCase {
    func testPauseAndResumeKeepStreamStateAndCommittedPageCount() throws {
        var value=ScrollSession(taskID:UUID(),axis:.horizontal)
        try value.apply(.selected);try value.apply(.recordingStarted)
        try value.apply(.pagePaused(0));try value.apply(.pagePaused(0))
        XCTAssertEqual(value.phase,.paused)
        XCTAssertThrowsError(try value.apply(.pageResumed(2)))
        try value.apply(.pageResumed(0)) // No frames before this pause.
        XCTAssertEqual(value.phase,.recording);XCTAssertEqual(value.page,0)
        try value.apply(.pagePaused(0));try value.apply(.pageResumed(1))
        try value.apply(.pageResumed(1)) // Duplicate state delivery is harmless.
        XCTAssertEqual(value.page,1);XCTAssertEqual(value.phase,.recording)
        XCTAssertThrowsError(try value.apply(.pageResumed(2)))
        try value.apply(.finish)
        try value.apply(.finish)
        XCTAssertEqual(value.phase,.sealing)
    }
    func testFinishAutomaticallyAdvancesThroughProcessingAndPhotos() throws {
        var value=ScrollSession(taskID:UUID(),axis:.vertical)
        try value.apply(.selected);try value.apply(.recordingStarted);try value.apply(.finish)
        try value.apply(.inputSealed);try value.apply(.reconstructed)
        try value.apply(.photosSaved(2))
        XCTAssertEqual(value.phase,.saved);XCTAssertEqual(value.savedPages,2)
        XCTAssertFalse(value.phase.unfinished)
    }
    func testExistingVideoInventorySurvivesSessionReadAndWrite() throws {
        let value = ScrollSession(taskID:UUID(),axis:.vertical)
        let source = ScrollRecording(path:try AssetPath("recording/a.mp4"),page:0,
            sha256:String(repeating:"a",count:64),bytes:100)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any])
        json["recordings"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode([source]))
        json["phase"] = "pausing" // Historical in-flight video state.
        var loaded = try JSONDecoder().decode(ScrollSession.self,from:JSONSerialization.data(withJSONObject:json))
        loaded.recover(hasResult:false,hasUncertainPhotoWrite:false)
        let saved = try JSONDecoder().decode(ScrollSession.self,from:JSONEncoder().encode(loaded))
        XCTAssertEqual(saved.recordings,[source]);XCTAssertEqual(saved.phase,.interrupted)
        try saved.validate()
    }
    func testCrashDuringSaveNeverTurnsUnknownWriteIntoRetry() throws {
        var value=ScrollSession(taskID:UUID(),axis:.vertical)
        try value.apply(.selected);try value.apply(.recordingStarted);try value.apply(.finish)
        try value.apply(.inputSealed);try value.apply(.reconstructed)
        value.recover(hasResult:true,hasUncertainPhotoWrite:true)
        XCTAssertEqual(value.phase,.saveUncertain)
        XCTAssertThrowsError(try value.retryKnownFailure(hasResult:true))
    }
    func testProcessingRecoveryDoesNotHaveOneShotViewFlag() throws {
        var value=ScrollSession(taskID:UUID(),axis:.vertical)
        try value.apply(.selected);try value.apply(.recordingStarted);try value.apply(.finish)
        try value.apply(.inputSealed)
        value.recover(hasResult:false,hasUncertainPhotoWrite:false)
        XCTAssertEqual(value.phase,.processing)
        value.recover(hasResult:true,hasUncertainPhotoWrite:false)
        XCTAssertEqual(value.phase,.saving)
    }
    func testNewWorkPreservesEarlierWorkAndRejectsConcurrentRecording() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let library=try ScrollLibrary(root:root)
        var (first,store,owner)=try library.begin(axis:.vertical)
        XCTAssertThrowsError(try library.begin(axis:.horizontal))
        try store.finishCapture(taskID:first.taskID,owner:owner,reason:.unknown)
        try first.apply(.failed("test interruption"));try library.save(first)
        let original=try Data(contentsOf:store.taskDirectory(first.taskID).appendingPathComponent("capture.json"))
        let (second,_,secondOwner)=try library.begin(axis:.horizontal)
        XCTAssertNotEqual(first.id,second.id)
        XCTAssertEqual(try Data(contentsOf:store.taskDirectory(first.taskID).appendingPathComponent("capture.json")),original)
        XCTAssertEqual(try library.sessions().count,2)
        withExtendedLifetime([owner,secondOwner]) {}
    }
    func testUnknownCaptureSchemaSurvivesAutomaticCleanup() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try TaskStore(root:root),pair=try store.beginCapture(now:Date.distantPast)
        let path=try store.taskDirectory(pair.0.taskID).appendingPathComponent("capture.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
        json["schemaVersion"]=999
        let bytes=try JSONSerialization.data(withJSONObject:json);try bytes.write(to:path)
        XCTAssertThrowsError(try store.cleanup(taskID:pair.0.taskID,explicit:false,now:Date.distantFuture))
        XCTAssertEqual(try Data(contentsOf:path),bytes)
        XCTAssertNotNil(try store.current())
        withExtendedLifetime(pair.1) {}
    }
    func testRecordedWorkDoesNotExpireWithoutExplicitDeletion() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try TaskStore(root:root),pair=try store.beginCapture(now:Date.distantPast)
        try store.finishCapture(taskID:pair.0.taskID,owner:pair.1,reason:.userStopped)
        XCTAssertFalse(try store.cleanup(taskID:pair.0.taskID,explicit:false,now:Date.distantFuture))
        XCTAssertNotNil(try store.current())
    }
}
