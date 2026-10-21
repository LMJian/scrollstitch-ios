import XCTest
@testable import ScrollStitchCore

final class CaptureEditingTests: XCTestCase {
    func testDragUsesDisplayedScaleAndOppositeEdgesStayPut() throws {
        let size=try PixelSize(width:1000,height:2000),original=CaptureInsets(top:100,bottom:200,left:20,right:40)
        let top=original.dragging(edge:"top",translation:40,displayedLength:400,in:size)
        XCTAssertEqual(top,CaptureInsets(top:300,bottom:200,left:20,right:40))
        XCTAssertEqual(original.dragging(edge:"bottom",translation:40,displayedLength:400,in:size).bottom,0)
        XCTAssertEqual(original.dragging(edge:"right",translation:-10,displayedLength:200,in:size).right,90)
    }
    func testCrossedHandlesRemainValidAndBadGeometryDoesNotChangeSelection() throws {
        let size=try PixelSize(width:884,height:1920),original=CaptureInsets(top:260,bottom:200)
        XCTAssertEqual(original.adjusting(edge:"top",to:Int.max,in:size).top,1656)
        XCTAssertEqual(original.adjusting(edge:"left",to:10000,in:size).left,860)
        XCTAssertEqual(original.dragging(edge:"top",translation:.infinity,displayedLength:400,in:size),original)
        XCTAssertEqual(original.dragging(edge:"top",translation:10,displayedLength:0,in:size),original)
    }
}
