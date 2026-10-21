#if !SCROLLSTITCH_COLLAGE_ONLY
import SwiftUI
import AlarmKit
import AppIntents
@preconcurrency import BackgroundTasks

struct WorkdayAlarmMetadata: AlarmMetadata {}

struct StopWorkdayAlarm: LiveActivityIntent {
    static let title: LocalizedStringResource = "关闭卷轴闹钟"
    static let openAppWhenRun = false
    @Parameter(title: "闹钟标识") var occurrenceID: String
    init() {}
    init(id: UUID) { occurrenceID = id.uuidString }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: occurrenceID) {
            await WorkdayAlarmService.shared.didStop(id)
        }
        return .result()
    }
}

@MainActor
final class NativeWorkdayAlarmSystem: WorkdayAlarmSystem {
    var authorization: WorkdayAlarmAuthorization {
        convert(AlarmManager.shared.authorizationState)
    }
    func requestAuthorization() async throws -> WorkdayAlarmAuthorization {
        convert(try await AlarmManager.shared.requestAuthorization())
    }
    private func convert(_ state: AlarmManager.AuthorizationState) -> WorkdayAlarmAuthorization {
        switch state {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func alarms() throws -> [WorkdaySystemAlarm] {
        try AlarmManager.shared.alarms.map { .init(id: $0.id, ringing: $0.state == .alerting) }
    }
    func schedule(_ occurrence: WorkdayAlarmOccurrence) async throws {
        let title = LocalizedStringResource(stringLiteral: occurrence.label)
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: .init(title: title)),
            metadata: WorkdayAlarmMetadata(), tintColor: Color.orange)
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(occurrence.date), attributes: attributes,
            stopIntent: StopWorkdayAlarm(id: occurrence.id))
        _ = try await AlarmManager.shared.schedule(id: occurrence.id, configuration: configuration)
    }
    func cancel(_ id: UUID) throws { try AlarmManager.shared.cancel(id: id) }
}

@MainActor
final class WorkdayAlarmService: ObservableObject {
    static let shared = WorkdayAlarmService()
    @Published private(set) var rules: [WorkdayAlarmRule] = []
    @Published private(set) var years: [Int: WorkdayHolidayStore.Year] = [:]
    @Published private(set) var report: WorkdayAlarmEngine.Report?
    @Published private(set) var authorization: WorkdayAlarmAuthorization = .notDetermined
    @Published private(set) var busy = false
    @Published private(set) var updating = false
    @Published private(set) var loaded = false
    @Published private(set) var automaticUpdates = true
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var updateMessage: String?
    private var engine: WorkdayAlarmEngine?
    private var catalog: WorkdayHolidayStore?
    private var needsRefresh = false
    private var shouldCheckAfterRefresh = false
    private init() {}
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkdayAlarms", isDirectory: true)
    }
    private var stateFile: URL { root.appendingPathComponent("alarms.json") }
    var datasets: [Int: HolidayDataset] { years.mapValues(\.dataset) }
    var next: WorkdayAlarmOccurrence? { report?.confirmed.first }

    private func load() throws {
        guard !loaded else { return }
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let annual = urls.filter { $0.lastPathComponent.range(of: #"^\d{4}\.v\d+\.json$"#, options: .regularExpression) != nil }
        guard !annual.isEmpty else { throw WorkdayError.invalidData("安装包中缺少年度安排") }
        let catalog = try WorkdayHolidayStore(bundleFiles: annual, cacheURL: root.appendingPathComponent("calendar.json"))
        let engine = try WorkdayAlarmEngine(file: stateFile, system: NativeWorkdayAlarmSystem())
        self.catalog = catalog; self.engine = engine; loaded = true
        copyState()
    }
    private func copyState() {
        guard let engine, let catalog else { return }
        rules = engine.state.rules; report = engine.report
        automaticUpdates = engine.state.automaticUpdates; authorization = engine.authorization
        years = catalog.years; checkedAt = catalog.checkedAt
    }

    func enter() async {
        shouldCheckAfterRefresh = true
        await refresh(requestPermission: false)
    }

    /// Foreground/background maintenance is entirely local. Using screenshots
    /// does not start a public-calendar download.
    @discardableResult
    func refreshExisting() async -> Bool {
        guard loaded || FileManager.default.fileExists(atPath: stateFile.path) else { return true }
        await refresh(requestPermission: false)
        return error == nil && report?.issues.isEmpty != false
    }

    func refresh(requestPermission: Bool = false, replacement: [WorkdayAlarmRule]? = nil) async {
        guard !busy else { needsRefresh = true; return }
        busy = true; error = nil
        do {
            try load()
            if !Task.isCancelled, let engine, let catalog {
                _ = try await engine.reconcile(rules: replacement, datasets: catalog.datasets,
                                               requestPermission: requestPermission)
                error = engine.report?.issues.first ?? catalog.warning
            }
        } catch { self.error = error.localizedDescription }
        copyState()
        await WorkdayAlarmBackground.enqueue(hasRules: rules.contains(where: \.enabled))
        busy = false
        if needsRefresh {
            needsRefresh = false
            await refresh()
        }
        if shouldCheckAfterRefresh && !updating {
            shouldCheckAfterRefresh = false
            if automaticUpdates, let catalog, !Task.isCancelled {
                let interval = Date().timeIntervalSince(catalog.attemptedAt ?? .distantPast)
                if interval > (catalog.checkedAt == nil ? 3600 : 86_400) { await updateCalendar() }
            }
        }
    }

    func save(_ rule: WorkdayAlarmRule) async -> Bool {
        // Downloads never block editing or scheduling against valid local data.
        // A completed update requests another reconciliation of the latest rules.
        guard !busy else { return false }
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { next.append(rule) }
        do {
            _ = try WorkdayPlanner.plan(rules: next, datasets: datasets, now: Date())
        } catch { self.error = error.localizedDescription; return false }
        await refresh(requestPermission: rule.enabled, replacement: next)
        // Settings may be saved even if permission or the system schedule failed;
        // the home screen then exposes that issue and confirmed coverage.
        return rules.contains(rule)
    }
    func toggle(_ rule: WorkdayAlarmRule, enabled: Bool) async {
        var changed = rule; changed.enabled = enabled
        _ = await save(changed)
    }
    func delete(_ rule: WorkdayAlarmRule) async {
        guard !busy else { return }
        await refresh(replacement: rules.filter { $0.id != rule.id })
    }
    func setAutomaticUpdates(_ enabled: Bool) {
        do { try engine?.setAutomaticUpdates(enabled); copyState() }
        catch { self.error = error.localizedDescription }
    }
    func updateCalendar() async {
        guard !updating, !busy else { return }
        updating = true; updateMessage = nil
        do {
            try load()
            if let catalog {
                let count = try await catalog.refresh()
                updateMessage = count == 0 ? "已检查，当前安排是最新版本。" : "已更新 \(count) 个年度，正在核对未来闹钟。"
            }
        } catch {
            updateMessage = "\(error.localizedDescription) 已有安排仍可离线使用。"
        }
        copyState(); updating = false
        await refresh()
    }
    func didStop(_ id: UUID) async {
        do {
            try load()
            try engine?.markCompleted(id)
        } catch { self.error = error.localizedDescription; return }
        await refresh()
    }
}

@MainActor
enum WorkdayAlarmBackground {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "local.scrollstitch.app") + ".refresh-alarms" }
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                let success = await WorkdayAlarmService.shared.refreshExisting()
                refresh.setTaskCompleted(success: success && !Task.isCancelled)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }
    static func enqueue(hasRules: Bool) async {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard hasRules else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(12 * 3600)
        // Opportunistic maintenance only. The UI reports already confirmed alarms.
        try? await BGTaskScheduler.shared.submitTaskRequest(request)
    }
}
#endif
