import XCTest
import CoreGraphics
import CoreText
@testable import ScrollStitchImaging

final class CaptureOverlayTests: XCTestCase {
    private func fixture(sharing: Bool = false, controls: Bool = false,
                         article: Bool = false) throws -> CGImage {
        let width=600,height=1300
        let context=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
            bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray:0.4,alpha:1)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        func text(_ value:String,x:CGFloat,top:CGFloat,size:CGFloat = 28) {
            let attributes:[NSAttributedString.Key:Any]=[
                NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("PingFangSC-Regular" as CFString,size,nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attributes))
            context.textPosition=CGPoint(x:x,y:CGFloat(height)-top)
            CTLineDraw(line,context)
        }
        // A saturated blurred card fails the old center-only neutral gate.
        context.setFillColor(red:0.35,green:0.52,blue:0.72,alpha:1)
        context.fill(CGRect(x:90,y:480,width:420,height:330))
        if sharing {
            text("屏幕共享",x:230,top:620,size:32)
            text("卷轴",x:180,top:710)
            text("停止共享",x:230,top:790,size:32)
        } else if controls {
            text("5G VPN",x:70,top:155)
            text("未在播放",x:360,top:375)
            text("专注模式",x:80,top:650)
        } else if article {
            // The same words in prose do not establish system-widget geometry.
            text("5G VPN",x:80,top:420)
            text("未在播放",x:80,top:480)
            text("专注模式",x:80,top:540)
        }
        return try XCTUnwrap(context.makeImage())
    }
    func testSharingPanelWithColoredBlurIsExcluded() throws {
        XCTAssertTrue(CaptureOverlayDetector.inspect(try fixture(sharing:true)).isSystemPanel)
    }
    func testControlCenterRequiresSystemWidgetPositions() throws {
        XCTAssertTrue(CaptureOverlayDetector.inspect(try fixture(controls:true)).isSystemPanel)
        XCTAssertFalse(CaptureOverlayDetector.inspect(try fixture(article:true)).isSystemPanel)
    }
    func testGrayBackdropAloneDoesNotDiscardContent() throws {
        XCTAssertFalse(CaptureOverlayDetector.inspect(try fixture()).isSystemPanel)
    }
}
