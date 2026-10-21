import XCTest
@testable import ScrollStitchCore

final class ContractsTests: XCTestCase {
    func testUnsafeAndMalformedPersistedValuesAreRejected() throws {
        for path in ["/etc/passwd", "../outside", "assets/../secret", "assets//x", "assets/./x", "assets/a\\b", "assets/%2e%2e"] {
            XCTAssertThrowsError(try AssetPath(path))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PixelSize.self, from: Data(#"{"width":0,"height":5}"#.utf8)))
        XCTAssertThrowsError(try PixelSize(width: Int.max, height: 2))
        let good = try AssetPath("assets/ABC-123.png")
        XCTAssertEqual(try JSONDecoder().decode(AssetPath.self, from: JSONEncoder().encode(good)), good)
    }
    func testSymlinkCannotEscapeTaskRoot() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("assets"), withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        XCTAssertThrowsError(try AssetPath("assets/private.png").resolved(in: root))
    }
    func testStaleCallbacksAreRejectedAfterCancellationNewRevisionAndNewTask() {
        var gate = OperationGate(); let task = UUID()
        let old = gate.begin(taskID: task, revision: 1)
        XCTAssertTrue(gate.accepts(old))
        gate.invalidate(); XCTAssertFalse(gate.accepts(old))
        let next = gate.begin(taskID: task, revision: 2)
        XCTAssertFalse(gate.accepts(old)); XCTAssertTrue(gate.accepts(next))
        _ = gate.begin(taskID: UUID(), revision: 2)
        XCTAssertFalse(gate.accepts(next))
    }
    func testSchemaAndFrameOrderAreValidated() throws {
        var snapshot = CaptureSnapshot(taskID: UUID(), startedAt: Date())
        snapshot.schemaVersion = 2
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.schemaVersion = 1
        let a = SourceAsset(path: try AssetPath("assets/a.png"), size: try PixelSize(width: 2, height: 2), sha256: String(repeating:"a",count:64))
        snapshot.frames = [FrameRecord(asset:a,ordinal:1,monotonicPTS:1)]
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.frames = [FrameRecord(asset:a,ordinal:0,monotonicPTS:1)]
        try snapshot.validate()
        snapshot.phase = .ended
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.endReason = .userStopped
        try snapshot.validate()
    }
}
