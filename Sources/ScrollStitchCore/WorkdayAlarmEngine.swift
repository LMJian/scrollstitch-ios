import Foundation

public enum WorkdayAlarmAuthorization: Sendable { case notDetermined, authorized, denied }

public struct WorkdaySystemAlarm: Sendable {
    public let id: UUID
    public let ringing: Bool
    public init(id: UUID, ringing: Bool = false) { self.id = id; self.ringing = ringing }
}

@MainActor
public protocol WorkdayAlarmSystem {
    var authorization: WorkdayAlarmAuthorization { get }
    func requestAuthorization() async throws -> WorkdayAlarmAuthorization
    func alarms() throws -> [WorkdaySystemAlarm]
    func schedule(_ occurrence: WorkdayAlarmOccurrence) async throws
    func cancel(_ id: UUID) throws
}

/// Desired settings and ownership are durable before calling AlarmKit. A crash
/// between schedule and readback can therefore be reconciled without duplicates.
@MainActor
public final class WorkdayAlarmEngine {
    public struct State: Codable, Sendable {
        public var schemaVersion = 1
        public var rules: [WorkdayAlarmRule] = []
        public var automaticUpdates = true
        public var owned: [WorkdayAlarmOccurrence] = []
        public var completed: Set<UUID> = []
        public init() {}
    }
    public struct Report: Sendable {
        public let confirmed: [WorkdayAlarmOccurrence]
        public let missingYears: Set<Int>
        public let issues: [String]
        public let unconfirmedCount: Int
        public let obsoleteCount: Int
        public let checkedAt: Date
    }
    public private(set) var state: State
    public private(set) var isBusy = false
    public private(set) var report: Report?
    private let file: URL
    private let system: any WorkdayAlarmSystem
    public var authorization: WorkdayAlarmAuthorization { system.authorization }

    public init(file: URL, system: any WorkdayAlarmSystem) throws {
        self.file = file; self.system = system
        if FileManager.default.fileExists(atPath: file.path) {
            let raw = try Data(contentsOf: file)
            guard raw.count < 2 * 1024 * 1024 else { throw WorkdayError.scheduling("闹钟设置文件过大，未覆盖原文件。") }
            state = try JSONDecoder().decode(State.self, from: raw)
            guard state.schemaVersion == 1, state.rules.count <= 8, state.owned.count <= 1024,
                  Set(state.rules.map(\.id)).count == state.rules.count,
                  Set(state.owned.map(\.id)).count == state.owned.count else {
                throw WorkdayError.scheduling("闹钟设置无法读取，原文件已保留。")
            }
            for rule in state.rules { try rule.validate() }
        } else { state = State() }
    }

    public func setAutomaticUpdates(_ enabled: Bool) throws {
        var next = state; next.automaticUpdates = enabled
        try WorkdayPersistence.write(next, to: file); state = next
    }

    public func markCompleted(_ id: UUID) throws {
        var next = state
        // Only our persisted events can be consumed by an intent.
        if next.owned.contains(where: { $0.id == id }) {
            next.completed.insert(id)
            try WorkdayPersistence.write(next, to: file); state = next
        }
    }

    @discardableResult
    public func reconcile(rules: [WorkdayAlarmRule]? = nil, datasets: [Int: HolidayDataset],
                          now: Date = Date(), requestPermission: Bool = false) async throws -> Report {
        guard !isBusy else { throw WorkdayError.scheduling("正在更新闹钟，请稍候再试。") }
        isBusy = true
        defer { isBusy = false }
        let rules = rules ?? state.rules
        let plan = try WorkdayPlanner.plan(rules: rules, datasets: datasets, now: now)
        let desired = plan.occurrences.filter { !state.completed.contains($0.id) }
        let desiredIDs = Set(desired.map(\.id))
        let oldOwned = Dictionary(uniqueKeysWithValues: state.owned.map { ($0.id, $0) })
        var next = state
        next.rules = rules
        var journal = oldOwned
        for item in desired { journal[item.id] = item }
        guard journal.count <= 1024 else {
            throw WorkdayError.scheduling("有过多系统状态尚未确认，请先重试核对，再修改闹钟。")
        }
        next.owned = Array(journal.values)
        try WorkdayPersistence.write(next, to: file); state = next

        var issues = [String](), actual = [WorkdaySystemAlarm]()
        var initialReadSucceeded = false
        do { actual = try system.alarms(); initialReadSucceeded = true }
        catch { issues.append("无法读取系统闹钟：\(error.localizedDescription)") }

        let enabledRules = Set(rules.filter(\.enabled).map(\.id))
        let retainedRinging = Set(actual.filter {
            $0.ringing && oldOwned[$0.id].map { enabledRules.contains($0.ruleID) } == true
                && !state.completed.contains($0.id)
        }.map(\.id))
        let ownedIDs = Set(journal.keys)
        var cancelled = Set<UUID>(), cancelFailed = false
        for alarm in actual where ownedIDs.contains(alarm.id) && !desiredIDs.contains(alarm.id)
            && !retainedRinging.contains(alarm.id) {
            do { try system.cancel(alarm.id); cancelled.insert(alarm.id) }
            catch {
                cancelFailed = true
                issues.append("有旧闹钟未能取消，请重试：\(error.localizedDescription)")
                break
            }
        }

        var authorization = system.authorization
        if requestPermission && authorization == .notDetermined && !desired.isEmpty {
            do { authorization = try await system.requestAuthorization() }
            catch { issues.append(error.localizedDescription) }
        }
        if !desired.isEmpty && authorization != .authorized {
            issues.append(WorkdayError.permissionDenied.localizedDescription)
        }
        // Failed reads/cancellations must not be followed by blind duplicate writes.
        if initialReadSucceeded && !cancelFailed && authorization == .authorized {
            let existing = Set(actual.map(\.id)).subtracting(cancelled)
            for item in desired where !existing.contains(item.id) && !state.completed.contains(item.id) {
                do { try await system.schedule(item) }
                catch {
                    issues.append("部分闹钟尚未排程，请重试：\(error.localizedDescription)")
                    break
                }
            }
        }
        var confirmedIDs = Set<UUID>()
        var finalReadSucceeded = false
        do {
            actual = try system.alarms()
            confirmedIDs = Set(actual.map(\.id))
            finalReadSucceeded = true
        } catch { issues.append("系统状态回读失败，请重新检查：\(error.localizedDescription)") }

        if finalReadSucceeded {
            // Preserve failed/uncertain writes, but prune entries verified absent.
            var clean = state
            clean.owned = journal.values.filter { desiredIDs.contains($0.id) || confirmedIDs.contains($0.id) }
            clean.completed = clean.completed.intersection(Set(clean.owned.map(\.id)))
            do { try WorkdayPersistence.write(clean, to: file); state = clean }
            catch { issues.append("排程已执行，但状态保存失败：\(error.localizedDescription)") }
        }
        let confirmed = authorization == .authorized
            ? desired.filter { confirmedIDs.contains($0.id) && !state.completed.contains($0.id) } : []
        let obsolete = confirmedIDs.intersection(ownedIDs).subtracting(desiredIDs).subtracting(retainedRinging).count
        let value = Report(confirmed: confirmed, missingYears: plan.missingYears, issues: issues,
                           unconfirmedCount: desired.count - confirmed.count, obsoleteCount: obsolete, checkedAt: now)
        report = value
        return value
    }
}
