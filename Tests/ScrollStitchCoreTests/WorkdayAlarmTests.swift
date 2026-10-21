import XCTest
@testable import ScrollStitchCore

private let annualRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Holidays")
private func annualBytes() throws -> Data { try Data(contentsOf: annualRoot.appendingPathComponent("2026.v1.json")) }
private func date(_ key: String, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    WorkdayClock.parse(key, hour: hour, minute: minute)!
}
private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("workday-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class WorkdayCalendarTests: XCTestCase {
    func testAll2026DaysAgainstIndependentOfficialOracle() throws {
        let dataset = try HolidayDataset.decode(annualBytes())
        var rest = Set<String>()
        for (month, first, last) in [(1,1,3),(2,15,23),(4,4,6),(5,1,5),(6,19,21),(9,25,27),(10,1,7)] {
            for day in first...last { rest.insert(String(format: "2026-%02d-%02d", month, day)) }
        }
        let makeup: Set<String> = ["2026-01-04","2026-02-14","2026-02-28","2026-05-09","2026-09-20","2026-10-10"]
        XCTAssertEqual(rest.count, 33)
        for offset in 0..<365 {
            let day = WorkdayClock.day(offset, after: date("2026-01-01"))
            let key = WorkdayClock.key(day)
            let weekday = WorkdayClock.calendar.component(.weekday, from: day)
            let expected = makeup.contains(key) || (!rest.contains(key) && (2...6).contains(weekday))
            let actual = WorkdayPlanner.decision(day: day, rule: .init(), datasets: [2026: dataset])
            XCTAssertEqual(actual.shouldRing, expected, key)
            if makeup.contains(key) { XCTAssertEqual(actual.kind, .makeup, key) }
            if rest.contains(key) { XCTAssertEqual(actual.kind, .holiday, key) }
        }
    }
    func testMissingYearDoesNotInventWorkdaysAndManualChoiceWins() throws {
        var rule = WorkdayAlarmRule()
        let unknown = date("2027-01-04")
        XCTAssertNil(WorkdayPlanner.decision(day: unknown, rule: rule, datasets: [:]).shouldRing)
        rule.exceptions["2027-01-04"] = true
        XCTAssertEqual(WorkdayPlanner.decision(day: unknown, rule: rule, datasets: [:]).kind, .customOn)
        rule.exceptions["2027-01-04"] = false
        XCTAssertEqual(WorkdayPlanner.decision(day: unknown, rule: rule, datasets: [:]).shouldRing, false)
        rule.exceptions = [:]; rule.mode = .everyday
        XCTAssertEqual(WorkdayPlanner.decision(day: unknown, rule: rule, datasets: [:]).shouldRing, true)
        rule.mode = .weekly; rule.weekdays = [1]
        XCTAssertEqual(WorkdayPlanner.decision(day: unknown, rule: rule, datasets: [:]).shouldRing, false)
    }
    func testPlannerBoundsSortAndNeverReplaysPastTime() throws {
        let rule = WorkdayAlarmRule(hour: 7, minute: 30, mode: .everyday)
        let result = try WorkdayPlanner.plan(rules: [rule], datasets: [:], now: date("2026-10-21", 7, 30))
        XCTAssertEqual(result.occurrences.count, 64)
        XCTAssertEqual(result.occurrences.first?.day, "2026-10-22")
        XCTAssertTrue(result.budgetReached)
        XCTAssertTrue(result.missingYears.isEmpty)
        XCTAssertEqual(result.occurrences.map(\.date), result.occurrences.map(\.date).sorted())
        XCTAssertEqual(Set(result.occurrences.map(\.id)).count, 64)
        let again = try WorkdayPlanner.plan(rules: [rule], datasets: [:], now: date("2026-10-21", 7, 31))
        XCTAssertEqual(result.occurrences, again.occurrences)
    }
    func testCrossYearStopsAtVerifiedCoverage() throws {
        let data = try HolidayDataset.decode(annualBytes())
        let result = try WorkdayPlanner.plan(rules: [.init()], datasets: [2026: data], now: date("2026-12-30"))
        XCTAssertEqual(result.occurrences.map(\.day), ["2026-12-30", "2026-12-31"])
        XCTAssertEqual(result.missingYears, [2027])
    }
    func testDateParsingAndBeijingTimeAreStrict() {
        for invalid in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-2-01", "2026-00-00", "2026-01-01Z", "２０２６-01-01"] {
            XCTAssertNil(WorkdayClock.parse(invalid), invalid)
        }
        XCTAssertNotNil(WorkdayClock.parse("2028-02-29"))
        let instant = date("2026-01-01", 7, 30)
        XCTAssertEqual(ISO8601DateFormatter().string(from: instant), "2025-12-31T23:30:00Z")
    }
    func testPersonalHolidayOverrideAndDuplicateTimeValidation() throws {
        let dataset = try HolidayDataset.decode(annualBytes())
        var rule = WorkdayAlarmRule(exceptions: ["2026-10-01": true, "2026-10-10": false])
        XCTAssertEqual(WorkdayPlanner.decision(day: date("2026-10-01"), rule: rule, datasets: [2026: dataset]).shouldRing, true)
        XCTAssertEqual(WorkdayPlanner.decision(day: date("2026-10-10"), rule: rule, datasets: [2026: dataset]).shouldRing, false)
        XCTAssertThrowsError(try WorkdayPlanner.plan(rules: [rule, .init()], datasets: [:], now: date("2026-01-01")))
        rule.enabled = false
        XCTAssertNoThrow(try WorkdayPlanner.plan(rules: [rule, .init()], datasets: [:], now: date("2026-01-01")))
        XCTAssertThrowsError(try WorkdayAlarmRule(mode: .weekly, weekdays: []).validate())
    }
    func testAnnualFilesRejectDuplicatesWrongSourceAndInvalidSchema() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: annualBytes()) as? [String: Any])
        var overrides = try XCTUnwrap(object["overrides"] as? [[String: Any]])
        overrides.append(overrides[0]); object["overrides"] = overrides
        XCTAssertThrowsError(try HolidayDataset.decode(JSONSerialization.data(withJSONObject: object)))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: annualBytes()) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try HolidayDataset.decode(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 1
        object["source"] = ["title":"Bad","url":"https://gov.cn.evil.example/","publishedAt":"2025-11-04"]
        XCTAssertThrowsError(try HolidayDataset.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testIndexRejectsTraversalDuplicateYearsAndOversize() throws {
        let bad = HolidayIndex(years: [.init(year: 2026, revision: 1, file: "../secret.json", sha256: String(repeating: "a", count: 64))])
        XCTAssertThrowsError(try HolidayIndex.decode(JSONEncoder().encode(bad)))
        let entry = HolidayIndex.Entry(year: 2026, revision: 1, file: "2026.v1.json", sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try HolidayIndex.decode(JSONEncoder().encode(HolidayIndex(years: [entry, entry]))))
        XCTAssertThrowsError(try HolidayIndex.decode(Data(repeating: 32, count: 65537)))
    }
}

private actor TestHolidayTransport: HolidayTransport {
    var files: [URL: Data]
    var calls: [URL] = []
    init(files: [URL: Data]) { self.files = files }
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        calls.append(url)
        guard let raw = files[url] else { throw WorkdayError.network("离线") }
        return raw
    }
    func replace(_ files: [URL: Data]) { self.files = files }
}

@MainActor
final class WorkdayStoreTests: XCTestCase {
    private let endpoint = WorkdayHolidayStore.endpoint
    private func bundle() -> [URL] { [annualRoot.appendingPathComponent("2026.v1.json")] }
    private func update(revision: Int = 2, year: Int = 2026) throws -> (URL, Data, Data) {
        let original = try HolidayDataset.decode(annualBytes())
        let dataset = HolidayDataset(year: year, revision: revision, source: original.source,
                                     overrides: year == 2026 ? original.overrides : [])
        let bytes = try JSONEncoder().encode(dataset)
        let file = "\(year).v\(revision).json"
        let index = HolidayIndex(years: [.init(year: year, revision: revision, file: file, sha256: WorkdayClock.digest(bytes))])
        return (endpoint.deletingLastPathComponent().appendingPathComponent(file), bytes, try JSONEncoder().encode(index))
    }
    func testDownloadedRevisionSurvivesOfflineRestartAndNewerBundleWins() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (url, bytes, index) = try update()
        let transport = TestHolidayTransport(files: [endpoint:index, url:bytes])
        let store = try WorkdayHolidayStore(bundleFiles: bundle(), cacheURL: root.appendingPathComponent("cache"), transport: transport)
        XCTAssertFalse(try XCTUnwrap(store.years[2026]).downloaded)
        let count = try await store.refresh(now: date("2026-10-21"))
        XCTAssertEqual(count, 1)
        let offline = try WorkdayHolidayStore(bundleFiles: bundle(), cacheURL: root.appendingPathComponent("cache"),
                                              transport: TestHolidayTransport(files: [:]))
        XCTAssertEqual(offline.years[2026]?.dataset.revision, 2)
        XCTAssertTrue(try XCTUnwrap(offline.years[2026]).downloaded)
        do { try await offline.refresh(); XCTFail("offline must fail") } catch {}
        XCTAssertEqual(offline.years[2026]?.dataset.revision, 2)
        let (_, newer, _) = try update(revision: 3)
        let bundled = root.appendingPathComponent("2026.v3.json"); try newer.write(to: bundled)
        let upgraded = try WorkdayHolidayStore(bundleFiles: [bundled], cacheURL: root.appendingPathComponent("cache"))
        XCTAssertEqual(upgraded.years[2026]?.dataset.revision, 3)
        XCTAssertFalse(try XCTUnwrap(upgraded.years[2026]).downloaded)
    }
    func testBadHashAndMissingFileDoNotReplaceGoodCache() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache")
        let (url, bytes, index) = try update()
        let transport = TestHolidayTransport(files: [endpoint:index, url:bytes])
        let store = try WorkdayHolidayStore(bundleFiles: bundle(), cacheURL: file, transport: transport)
        try await store.refresh()
        let saved = try Data(contentsOf: file)
        let (nextURL, _, nextIndex) = try update(revision: 3)
        await transport.replace([endpoint:nextIndex, nextURL:Data("corrupted".utf8)])
        do { try await store.refresh(); XCTFail("hash must fail") } catch {}
        XCTAssertEqual(store.years[2026]?.dataset.revision, 2)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        await transport.replace([endpoint:nextIndex])
        do { try await store.refresh(); XCTFail("missing file must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }
    func testLowerRevisionAndUnchangedIndexDoNotRedownload() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (url, bytes, index) = try update()
        let transport = TestHolidayTransport(files: [endpoint:index, url:bytes])
        let store = try WorkdayHolidayStore(bundleFiles: bundle(), cacheURL: root.appendingPathComponent("cache"), transport: transport)
        try await store.refresh()
        let again = try await store.refresh()
        XCTAssertEqual(again, 0)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == url }.count, 1)
        let originalIndex = try Data(contentsOf: annualRoot.appendingPathComponent("index.json"))
        await transport.replace([endpoint:originalIndex])
        try await store.refresh()
        XCTAssertEqual(store.years[2026]?.dataset.revision, 2)
    }
    func testAtomicMultiYearUpdateKeepsOldDataIfSecondFileFails() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (url, bytes, _) = try update()
        let (_, future, _) = try update(revision: 1, year: 2027)
        let index = HolidayIndex(years: [
            .init(year: 2026, revision: 2, file: "2026.v2.json", sha256: WorkdayClock.digest(bytes)),
            .init(year: 2027, revision: 1, file: "2027.v1.json", sha256: WorkdayClock.digest(future))
        ])
        let transport = TestHolidayTransport(files: [endpoint:try JSONEncoder().encode(index), url:bytes])
        let cache = root.appendingPathComponent("cache")
        let store = try WorkdayHolidayStore(bundleFiles: bundle(), cacheURL: cache, transport: transport)
        do { try await store.refresh(); XCTFail("second file missing") } catch {}
        XCTAssertEqual(store.years[2026]?.dataset.revision, 1)
        XCTAssertNil(store.years[2027])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    func testCorruptCacheFallsBackWithoutDeletingItAndRejectsSameVersionRewrite() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache"), damaged = Data("{incomplete".utf8)
        try damaged.write(to: file)
        let (_, _, rewriteIndex) = try update(revision: 1) // Different serialization of the same version is still immutable.
        let store = try WorkdayHolidayStore(bundleFiles: bundle(), cacheURL: file,
                                            transport: TestHolidayTransport(files: [endpoint:rewriteIndex]))
        XCTAssertEqual(store.years[2026]?.dataset.revision, 1)
        XCTAssertNotNil(store.warning)
        do { try await store.refresh(); XCTFail("same version changed") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }
}

@MainActor
private final class TestAlarmSystem: WorkdayAlarmSystem {
    var authorization: WorkdayAlarmAuthorization = .authorized
    var answer: WorkdayAlarmAuthorization = .authorized
    var stored: [UUID: WorkdaySystemAlarm] = [:]
    var scheduleCalls = 0, requests = 0, cancelCalls = 0
    var capacity = 1000
    var failCancel = false, failRead = false, throwAfterWrite = false
    var beforeSchedule: (() throws -> Void)?
    func requestAuthorization() async throws -> WorkdayAlarmAuthorization {
        requests += 1; authorization = answer; return answer
    }
    func alarms() throws -> [WorkdaySystemAlarm] {
        if failRead { throw WorkdayError.scheduling("read error") }
        return Array(stored.values)
    }
    func schedule(_ occurrence: WorkdayAlarmOccurrence) async throws {
        try beforeSchedule?()
        scheduleCalls += 1
        guard stored.count < capacity else { throw WorkdayError.scheduling("capacity") }
        stored[occurrence.id] = WorkdaySystemAlarm(id: occurrence.id)
        if throwAfterWrite { throw WorkdayError.scheduling("uncertain write") }
    }
    func cancel(_ id: UUID) throws {
        cancelCalls += 1
        if failCancel { throw WorkdayError.scheduling("cancel error") }
        stored.removeValue(forKey: id)
    }
}

@MainActor
final class WorkdayEngineTests: XCTestCase {
    func testDownloadedCorrectionReconcilesBothDayKindsAndSurvivesOfflineRestart() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try HolidayDataset.decode(annualBytes())
        // Test-only correction: swap an existing makeup day and a holiday.
        // Never publish these synthetic dates to the production endpoint.
        let changed = HolidayDataset(year: 2026, revision: 2, source: original.source,
            overrides: original.overrides.filter { !["2026-09-20", "2026-10-01"].contains($0.date) } + [
                .init(date: "2026-09-20", kind: .rest, name: "测试休息日"),
                .init(date: "2026-10-01", kind: .work, name: "测试工作日")])
        let bytes = try JSONEncoder().encode(changed)
        let index = HolidayIndex(years: [.init(year: 2026, revision: 2, file: "2026.v2.json",
                                              sha256: WorkdayClock.digest(bytes))])
        let endpoint = WorkdayHolidayStore.endpoint
        let transport = TestHolidayTransport(files: [endpoint: try JSONEncoder().encode(index),
            endpoint.deletingLastPathComponent().appendingPathComponent("2026.v2.json"): bytes])
        let bundle = [annualRoot.appendingPathComponent("2026.v1.json")]
        let cache = root.appendingPathComponent("calendar"), state = root.appendingPathComponent("alarms")
        let catalog = try WorkdayHolidayStore(bundleFiles: bundle, cacheURL: cache, transport: transport)
        let system = TestAlarmSystem(), now = date("2026-09-20")
        let engine = try WorkdayAlarmEngine(file: state, system: system)
        let before = try await engine.reconcile(rules: [.init()], datasets: catalog.years.mapValues(\.dataset), now: now)
        let removed = try XCTUnwrap(before.confirmed.first(where: { $0.day == "2026-09-20" }))
        XCTAssertFalse(before.confirmed.contains(where: { $0.day == "2026-10-01" }))
        try await catalog.refresh(now: now)
        let after = try await engine.reconcile(datasets: catalog.years.mapValues(\.dataset), now: now)
        XCTAssertNil(system.stored[removed.id])
        XCTAssertFalse(after.confirmed.contains(where: { $0.day == "2026-09-20" }))
        let added = try XCTUnwrap(after.confirmed.first(where: { $0.day == "2026-10-01" }))
        XCTAssertNotNil(system.stored[added.id])
        await transport.replace([:])
        let offline = try WorkdayHolidayStore(bundleFiles: bundle, cacheURL: cache, transport: transport)
        do { try await offline.refresh(); XCTFail("Network is unavailable") } catch {}
        let restarted = try WorkdayAlarmEngine(file: state, system: system)
        let calls = system.scheduleCalls
        let recovered = try await restarted.reconcile(datasets: offline.years.mapValues(\.dataset), now: now)
        XCTAssertEqual(recovered.confirmed.map(\.id), after.confirmed.map(\.id))
        XCTAssertEqual(system.scheduleCalls, calls)
    }
    func testSaveReadbackRestartIdempotenceAndDisable() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state")
        let system = TestAlarmSystem()
        let engine = try WorkdayAlarmEngine(file: file, system: system)
        var rule = WorkdayAlarmRule(mode: .everyday)
        system.beforeSchedule = {
            let saved = try JSONDecoder().decode(WorkdayAlarmEngine.State.self, from: Data(contentsOf: file))
            XCTAssertEqual(saved.rules, [rule])
            XCTAssertFalse(saved.owned.isEmpty, "intent must persist before writes")
        }
        let first = try await engine.reconcile(rules: [rule], datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(first.confirmed.count, 64)
        XCTAssertEqual(first.unconfirmedCount, 0)
        XCTAssertTrue(first.issues.isEmpty)
        system.beforeSchedule = nil
        let restarted = try WorkdayAlarmEngine(file: file, system: system)
        try await restarted.reconcile(datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(system.scheduleCalls, 64, "restart must not duplicate alarms")
        rule.enabled = false
        let disabled = try await restarted.reconcile(rules: [rule], datasets: [:], now: date("2026-10-21"))
        XCTAssertTrue(disabled.confirmed.isEmpty)
        XCTAssertTrue(system.stored.isEmpty)
        XCTAssertEqual(restarted.state.rules.first?.enabled, false)
    }
    func testDeniedPermissionPersistsSettingsButReportsNoSuccess() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem(); system.authorization = .notDetermined; system.answer = .denied
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        let result = try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:],
                                               now: date("2026-10-21"), requestPermission: true)
        XCTAssertEqual(system.requests, 1)
        XCTAssertEqual(system.scheduleCalls, 0)
        XCTAssertTrue(result.confirmed.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertEqual(engine.state.rules.count, 1)
    }
    func testPartialCapacityReportsOnlyActuallyScheduledAndRecovers() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem(); system.capacity = 3
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        let result = try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(result.confirmed.map(\.day), ["2026-10-21","2026-10-22","2026-10-23"])
        XCTAssertEqual(result.unconfirmedCount, 61)
        XCTAssertFalse(result.issues.isEmpty)
        system.capacity = 100
        let recovered = try await engine.reconcile(datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(recovered.confirmed.count, 64)
        XCTAssertEqual(Set(recovered.confirmed.map(\.id)).count, system.stored.count)
    }
    func testUncertainWriteIsReadBackAndNotDuplicatedOnRetry() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem(); system.throwAfterWrite = true
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        let first = try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(first.confirmed.count, 1)
        system.throwAfterWrite = false
        let second = try await engine.reconcile(datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(second.confirmed.count, 64)
        XCTAssertEqual(system.scheduleCalls, 64)
    }
    func testFailedCancelPreventsConflictingReplacementsAndCanBeRetriedAfterDelete() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem()
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        var rule = WorkdayAlarmRule(mode: .everyday)
        try await engine.reconcile(rules: [rule], datasets: [:], now: date("2026-10-21"))
        system.failCancel = true; rule.hour = 8
        let changed = try await engine.reconcile(rules: [rule], datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(system.scheduleCalls, 64)
        XCTAssertEqual(changed.obsoleteCount, 64)
        XCTAssertTrue(changed.confirmed.isEmpty)
        let deleted = try await engine.reconcile(rules: [], datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(deleted.obsoleteCount, 64)
        XCTAssertTrue(engine.state.rules.isEmpty)
        system.failCancel = false
        let recovered = try await engine.reconcile(datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(recovered.obsoleteCount, 0)
        XCTAssertTrue(system.stored.isEmpty)
    }
    func testReadFailureDoesNotBlindlyScheduleAndCorruptSettingsArePreserved() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state"), system = TestAlarmSystem()
        system.failRead = true
        let engine = try WorkdayAlarmEngine(file: file, system: system)
        let report = try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:], now: date("2026-10-21"))
        XCTAssertEqual(system.scheduleCalls, 0)
        XCTAssertTrue(report.confirmed.isEmpty)
        XCTAssertFalse(report.issues.isEmpty)
        let raw = Data("corrupt state".utf8); try raw.write(to: file)
        XCTAssertThrowsError(try WorkdayAlarmEngine(file: file, system: system))
        XCTAssertEqual(try Data(contentsOf: file), raw)
    }
    func testForegroundDoesNotStopRingingButUserDisableDoes() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem()
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        var rule = WorkdayAlarmRule(mode: .everyday)
        let first = try await engine.reconcile(rules: [rule], datasets: [:], now: date("2026-10-21"))
        let ringing = try XCTUnwrap(first.confirmed.first?.id)
        system.stored[ringing] = WorkdaySystemAlarm(id: ringing, ringing: true)
        try await engine.reconcile(datasets: [:], now: date("2026-10-21", 7, 31))
        XCTAssertNotNil(system.stored[ringing])
        rule.enabled = false
        try await engine.reconcile(rules: [rule], datasets: [:], now: date("2026-10-21", 7, 31))
        XCTAssertNil(system.stored[ringing])
    }
    func testStopCallbackReplenishesAndDoesNotRescheduleConsumedAlarm() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem()
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        let first = try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:], now: date("2026-10-21"))
        let id = try XCTUnwrap(first.confirmed.first?.id)
        try engine.markCompleted(id)
        let result = try await engine.reconcile(datasets: [:], now: date("2026-10-21", 7, 31))
        XCTAssertFalse(result.confirmed.map(\.id).contains(id))
        XCTAssertNil(system.stored[id])
        XCTAssertEqual(result.confirmed.count, 64)
    }
    func testActualBundledRulesAndPersonalChangeReachSystemReconciliation() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem()
        let dataset = try HolidayDataset.decode(annualBytes())
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        var rule = WorkdayAlarmRule()
        let first = try await engine.reconcile(rules: [rule], datasets: [2026: dataset], now: date("2026-09-20"))
        XCTAssertEqual(first.confirmed.first?.day, "2026-09-20", "Sunday makeup must ring")
        XCTAssertEqual(first.confirmed.first?.reason, "国庆节补班")
        XCTAssertFalse(first.confirmed.contains(where: { $0.day == "2026-10-01" }))
        let oldFirst = try XCTUnwrap(first.confirmed.first?.id)
        rule.exceptions["2026-09-20"] = false
        rule.exceptions["2026-10-01"] = true
        let changed = try await engine.reconcile(rules: [rule], datasets: [2026: dataset], now: date("2026-09-20"))
        XCTAssertNil(system.stored[oldFirst])
        XCTAssertTrue(changed.confirmed.contains(where: { $0.day == "2026-10-01" }))
        XCTAssertEqual(changed.confirmed.first?.day, "2026-09-21")
    }
    func testRevokedPermissionDoesNotDisplayExistingIDsAsConfirmedCoverage() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem()
        let engine = try WorkdayAlarmEngine(file: root.appendingPathComponent("state"), system: system)
        try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:], now: date("2026-10-21"))
        system.authorization = .denied
        let result = try await engine.reconcile(datasets: [:], now: date("2026-10-21"))
        XCTAssertTrue(result.confirmed.isEmpty)
        XCTAssertEqual(result.unconfirmedCount, 64)
        XCTAssertFalse(result.issues.isEmpty)
    }
    func testPersistFailureDoesNotModifySystemAndUnownedAlarmIsNeverCancelled() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let system = TestAlarmSystem(), external = UUID()
        system.stored[external] = WorkdaySystemAlarm(id: external)
        let parentFile = root.appendingPathComponent("parent")
        let engine = try WorkdayAlarmEngine(file: parentFile.appendingPathComponent("state"), system: system)
        try Data("not a directory".utf8).write(to: parentFile)
        do {
            try await engine.reconcile(rules: [.init(mode: .everyday)], datasets: [:], now: date("2026-10-21"))
            XCTFail("must fail before scheduling")
        } catch {}
        XCTAssertEqual(system.scheduleCalls, 0)
        XCTAssertEqual(system.cancelCalls, 0)
        XCTAssertNotNil(system.stored[external])
    }
}
