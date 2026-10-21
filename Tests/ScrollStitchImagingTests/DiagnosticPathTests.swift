import XCTest
import Foundation
import ScrollStitchImaging

final class DiagnosticPathTests: XCTestCase {
    func testAliasesAndUnicodeProduceTheSameRelativePath() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let root=base.appendingPathComponent("素材📷"), alias=base.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("nested"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
        let file=root.appendingPathComponent("nested/source.png")
        try Data([1]).write(to:file)
        XCTAssertEqual(try BoundaryDiagnostics.relativePath(of:file,under:alias),"nested/source.png")
        XCTAssertEqual(try BoundaryDiagnostics.relativePath(of:alias.appendingPathComponent("nested/source.png"),under:root),"nested/source.png")
        XCTAssertThrowsError(try BoundaryDiagnostics.relativePath(of:root,under:root))
    }
    func testSiblingPrefixAndSymlinkEscapeAreRejected() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let root=base.appendingPathComponent("store"), sibling=base.appendingPathComponent("store-other")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:sibling,withIntermediateDirectories:true)
        let file=sibling.appendingPathComponent("source.png"); try Data([1]).write(to:file)
        let link=root.appendingPathComponent("escape");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:sibling)
        XCTAssertThrowsError(try BoundaryDiagnostics.relativePath(of:file,under:root))
        XCTAssertThrowsError(try BoundaryDiagnostics.relativePath(of:link.appendingPathComponent("source.png"),under:root))
    }
}
