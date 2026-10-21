import ScrollStitchCore
import Foundation

/// A small luminance image drives selection; timestamps remain a safety ceiling,
/// not the sole reason to discard incoming screen content.
public struct CaptureMotionSampler {
    private var reference:[UInt8]?
    private var lastSelection:Double?
    private var lastObservation:Double?
    public init() {}
    public mutating func shouldObserve(at time:Double) -> Bool {
        guard time.isFinite, lastObservation.map({time-$0>=1.0/10}) ?? true else { return false }
        lastObservation=time;return true
    }
    public mutating func select(_ pixels:[UInt8],width:Int,height:Int,at time:Double) -> Bool {
        guard pixels.count==width*height,width>=16,height>=32,time.isFinite else { return false }
        defer { if reference == nil { reference=pixels;lastSelection=time } }
        guard let old=reference else { return true }
        guard old.count==pixels.count else { reference=pixels;lastSelection=time;return true }
        let top=height/5,bottom=height*4/5,left=width/10,right=width*9/10
        func cost(_ shift:Int) -> Double {
            let lo=max(top,top-shift),hi=min(bottom,bottom-shift)
            guard hi-lo>=height/5 else { return .infinity }
            var sum=0,count=0
            for y in stride(from:lo,to:hi,by:3) {
                for x in stride(from:left,to:right,by:3) {
                    // Gradients emphasize content instead of blank background and fixed bars.
                    let a=Int(old[(y+shift)*width+x])-Int(old[(y+shift)*width+x-1])
                    let b=Int(pixels[y*width+x])-Int(pixels[y*width+x-1])
                    sum+=abs(a-b);count+=1
                }
            }
            return Double(sum)/Double(max(1,count))
        }
        let stationary=cost(0)
        var best=stationary,offset=0
        for dy in stride(from:-height/2,through:height/2,by:2) {
            let score=cost(dy)
            if score<best { best=score;offset=dy }
        }
        let elapsed=time-(lastSelection ?? time)
        let moved=abs(offset)>=height/5 && best<stationary*0.85
        let uncertain=stationary>3 && best>stationary*0.85 && elapsed>=0.15
        let drift=stationary>1.2 && elapsed>=0.8
        if moved || uncertain || drift {
            reference=pixels;lastSelection=time;return true
        }
        return false
    }
}
