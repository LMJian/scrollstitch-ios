import XCTest
@testable import ScrollStitchCore

final class BenchmarkStatisticsTests: XCTestCase {
    private func trials(count: Int = 30, thermal: Int = 0, samples: Int = 3) -> [BenchmarkTrial] {
        (1...count).map { BenchmarkTrial(round:$0,elapsedSeconds:Double(31-$0),sampledPeakRSSBytes:UInt64($0*100),
            rssSampleCount:samples,thermalBefore:0,thermalAfter:thermal) }
    }
    func testP95UsesSortedNearestRankAndMeasuredPeak() throws {
        let result=try BenchmarkSummary.complete(trials())
        XCTAssertEqual(result.rounds,30); XCTAssertEqual(result.p95Seconds,29)
        XCTAssertEqual(result.maximumSampledRSSBytes,3000)
    }
    func testIncompleteDuplicateRoundsOrMissingSamplesCannotLookComplete() throws {
        XCTAssertThrowsError(try BenchmarkSummary.complete(trials(count:29)))
        var duplicated=trials(); duplicated[29]=duplicated[0]
        XCTAssertThrowsError(try BenchmarkSummary.complete(duplicated))
        XCTAssertThrowsError(try BenchmarkSummary.complete(trials(samples:0)))
    }
    func testThermalOrInvalidTimingCannotBeAcceptedAsNormalTemperatureRun() throws {
        XCTAssertThrowsError(try BenchmarkSummary.complete(trials(thermal:1)))
        for duration in [Double.nan,Double.infinity,0,-1] {
            var invalid=trials()
            invalid[0]=BenchmarkTrial(round:1,elapsedSeconds:duration,sampledPeakRSSBytes:100,
                rssSampleCount:1,thermalBefore:0,thermalAfter:0)
            XCTAssertThrowsError(try BenchmarkSummary.complete(invalid))
        }
    }
}
