import Foundation
@preconcurrency import AVFoundation
import CoreVideo

public struct CaptureVideoSegment: Codable, Sendable {
    public let path:AssetPath
    public let startPTS:Double
    public let endPTS:Double
    public let orientation:Int
    public let bytes:Int
    public let sha256:String
    public init(path:AssetPath,startPTS:Double,endPTS:Double,orientation:Int,bytes:Int,sha256:String) {
        self.path=path;self.startPTS=startPTS;self.endPTS=endPTS;self.orientation=orientation;self.bytes=bytes;self.sha256=sha256
    }
}
public struct CaptureVideoIndex: Codable, Sendable {
    public var version=1
    public var segments:[CaptureVideoSegment]=[]
    public var droppedSamples=0
    public var droppedTimeRanges:[[Double]]=[]
    public var finished=false
    public init() {}
}

