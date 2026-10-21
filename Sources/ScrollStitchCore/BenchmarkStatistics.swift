import Foundation

public struct BenchmarkTrial: Codable, Sendable {
    public let round: Int
    public let elapsedSeconds: Double
    public let sampledPeakRSSBytes: UInt64
    public let rssSampleCount: Int
    public let thermalBefore: Int
    public let thermalAfter: Int
    public init(round: Int, elapsedSeconds: Double, sampledPeakRSSBytes: UInt64,
                rssSampleCount: Int, thermalBefore: Int, thermalAfter: Int) {
        self.round=round; self.elapsedSeconds=elapsedSeconds; self.sampledPeakRSSBytes=sampledPeakRSSBytes
        self.rssSampleCount=rssSampleCount; self.thermalBefore=thermalBefore; self.thermalAfter=thermalAfter
    }
}
public struct BenchmarkSummary: Codable, Sendable {
    public let rounds: Int
    public let p95Seconds: Double
    public let maximumSampledRSSBytes: UInt64
    public static func complete(_ trials: [BenchmarkTrial]) throws -> BenchmarkSummary {
        guard trials.count == 30, trials.map(\.round) == Array(1...30), trials.allSatisfy({
            $0.elapsedSeconds.isFinite && $0.elapsedSeconds > 0 && $0.sampledPeakRSSBytes > 0 &&
            $0.rssSampleCount > 0 && $0.thermalBefore == 0 && $0.thermalAfter == 0
        }) else { throw ScrollStitchError.corruptData }
        let sorted=trials.map(\.elapsedSeconds).sorted()
        return BenchmarkSummary(rounds:30,p95Seconds:sorted[Int(ceil(Double(sorted.count)*0.95))-1],
            maximumSampledRSSBytes:trials.map(\.sampledPeakRSSBytes).max()!)
    }
}
