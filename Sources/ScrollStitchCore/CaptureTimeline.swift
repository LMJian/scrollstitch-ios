import Foundation

/// Timestamps are accepted source CMSampleBuffer PTS, not inferred frame indices.
/// Video decoding still enumerates the archive's actual encoded PTS separately.
public struct CaptureTimeline:Codable,Sendable {
    public struct Sample:Codable,Sendable {
        public let value:Int64
        public let timescale:Int32
        public let segment:Int
        public let width:Int
        public let height:Int
        public let orientation:Int
        public init(value:Int64,timescale:Int32,segment:Int,width:Int,height:Int,orientation:Int) {
            self.value=value;self.timescale=timescale;self.segment=segment;self.width=width;self.height=height;self.orientation=orientation
        }
    }
    public struct Event:Codable,Sendable {
        public let reason:String
        public var count:Int
        public let lower:Double
        public var upper:Double
    }
    public var version=2
    public var acceptedSourceSamples:[Sample]=[]
    public var events:[Event]=[]
    public var segmentHashes:[String]=[]
    public var finished=false
    public init() {}
    public func validate() throws {
        guard version==2 else { throw ScrollStitchError.unsupportedSchema }
        guard acceptedSourceSamples.count<=4000,events.count<=1024,segmentHashes.count<=64,
              acceptedSourceSamples.allSatisfy({$0.value>=0 && $0.timescale>0 && segmentHashes.indices.contains($0.segment) &&
                $0.width>0 && $0.width<=4096 && $0.height>0 && $0.height<=8192 && (1...8).contains($0.orientation)}),
              events.allSatisfy({$0.count>0 && $0.lower.isFinite && $0.upper.isFinite && $0.lower>=0 && $0.upper >= $0.lower}),
              segmentHashes.allSatisfy({$0.count==64}) else { throw ScrollStitchError.corruptData }
    }
    public mutating func event(_ reason:String,count:Int=1,lower:Double,upper:Double) {
        guard count>0,lower.isFinite,upper.isFinite,lower>=0,upper>=lower else { return }
        if let last=events.last,last.reason==reason,lower<=last.upper+0.1 {
            events[events.count-1].count+=count;events[events.count-1].upper=max(last.upper,upper)
        } else if events.count<1024 { events.append(Event(reason:reason,count:count,lower:lower,upper:upper)) }
        // Bounded aggregation preserves reasons after the detailed event budget.
        else if let i=events.lastIndex(where:{$0.reason==reason}) {
            events[i].count+=count;events[i].upper=max(events[i].upper,upper)
        }
    }
}
