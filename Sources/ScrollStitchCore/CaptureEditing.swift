import Foundation

public struct CaptureInsets: Equatable, Sendable {
    public var top: Int, bottom: Int, left: Int, right: Int
    public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.top=top;self.bottom=bottom;self.left=left;self.right=right
    }
    public func adjusting(edge: String, to value: Int, in size: PixelSize) -> CaptureInsets {
        var next=self
        switch edge {
        case "top": next.top=max(0,min(value,size.height-bottom-min(64,size.height)))
        case "bottom": next.bottom=max(0,min(value,size.height-top-min(64,size.height)))
        case "left": next.left=max(0,min(value,size.width-right-min(24,size.width)))
        case "right": next.right=max(0,min(value,size.width-left-min(24,size.width)))
        default: break
        }
        return next
    }
    public func dragging(edge: String, translation: Double, displayedLength: Double, in size: PixelSize) -> CaptureInsets {
        guard translation.isFinite,displayedLength.isFinite,displayedLength>0 else { return self }
        let vertical=edge == "top" || edge == "bottom"
        let base=edge == "top" ? top : edge == "bottom" ? bottom : edge == "left" ? left : right
        let delta=translation/displayedLength*Double(vertical ? size.height : size.width)
        let target=Double(base)+((edge == "bottom" || edge == "right") ? -delta : delta)
        let bounded=max(0,min(target,Double(vertical ? size.height : size.width)))
        return adjusting(edge:edge,to:Int(bounded.rounded()),in:size)
    }
}
