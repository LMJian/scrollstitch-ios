import Foundation
import CryptoKit

public enum WorkdayError: Error, LocalizedError, Equatable, Sendable {
    case invalidData(String)
    case network(String)
    case permissionDenied
    case scheduling(String)
    public var errorDescription: String? {
        switch self {
        case .invalidData(let reason): return "年度数据无效：\(reason)"
        case .network(let reason): return "暂时无法更新：\(reason)"
        case .permissionDenied: return "请允许卷轴使用闹钟，才能按时响铃。"
        case .scheduling(let reason): return reason
        }
    }
}

/// A calendar date is never interpreted using the device's locale or timezone.
public enum WorkdayClock {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }
    public static func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func parse(_ key: String, hour: Int = 12, minute: Int = 0) -> Date? {
        guard key.utf8.count == 10, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let pieces = key.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              key.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(pieces[0]), (2020...2100).contains(year),
              let month = Int(pieces[1]), let day = Int(pieces[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
              self.key(date) == key else { return nil }
        return date
    }
    public static func day(_ offset: Int, after date: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date))!
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct HolidayDataset: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public let title: String
        public let url: URL
        public let publishedAt: String
        public init(title: String, url: URL, publishedAt: String) {
            self.title = title; self.url = url; self.publishedAt = publishedAt
        }
    }
    public struct Override: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case rest, work }
        public let date: String
        public let kind: Kind
        public let name: String
        public init(date: String, kind: Kind, name: String) {
            self.date = date; self.kind = kind; self.name = name
        }
    }
    public let schemaVersion: Int
    public let region: String
    public let year: Int
    public let revision: Int
    public let timeZone: String
    public let source: Source
    public let overrides: [Override]
    public init(year: Int, revision: Int, source: Source, overrides: [Override]) {
        schemaVersion = 1; region = "CN"; timeZone = "Asia/Shanghai"
        self.year = year; self.revision = revision; self.source = source; self.overrides = overrides
    }
    public static func decode(_ raw: Data) throws -> Self {
        guard raw.count <= 128 * 1024 else { throw WorkdayError.invalidData("文件过大") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: raw) }
        catch { throw WorkdayError.invalidData("文件格式不正确") }
        try value.validate()
        return value
    }
    public func validate() throws {
        guard schemaVersion == 1, region == "CN", timeZone == "Asia/Shanghai",
              (2020...2100).contains(year), revision > 0, revision <= 1_000_000 else {
            throw WorkdayError.invalidData("不支持的协议、年份或版本")
        }
        guard !source.title.isEmpty, source.title.count <= 200,
              source.url.scheme == "https", let host = source.url.host,
              host == "gov.cn" || host.hasSuffix(".gov.cn"),
              WorkdayClock.parse(source.publishedAt) != nil else {
            throw WorkdayError.invalidData("缺少有效的官方来源")
        }
        guard overrides.count <= 366 else { throw WorkdayError.invalidData("日期数量超过一年") }
        var dates = Set<String>()
        for item in overrides {
            guard let date = WorkdayClock.parse(item.date),
                  WorkdayClock.calendar.component(.year, from: date) == year,
                  dates.insert(item.date).inserted,
                  !item.name.isEmpty, item.name.count <= 40 else {
                throw WorkdayError.invalidData("日期重复、越界或名称无效")
            }
        }
    }
    public func override(on day: String) -> Override? { overrides.first { $0.date == day } }
}

public struct HolidayIndex: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let year: Int
        public let revision: Int
        public let file: String
        public let sha256: String
        public init(year: Int, revision: Int, file: String, sha256: String) {
            self.year = year; self.revision = revision; self.file = file; self.sha256 = sha256
        }
    }
    public let schemaVersion: Int
    public let region: String
    public let years: [Entry]
    public init(years: [Entry]) { schemaVersion = 1; region = "CN"; self.years = years }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw WorkdayError.invalidData("索引过大") }
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == 1, value.region == "CN",
              !value.years.isEmpty, value.years.count <= 16 else {
            throw WorkdayError.invalidData("不支持的索引格式")
        }
        var years = Set<Int>()
        for entry in value.years {
            guard (2020...2100).contains(entry.year), years.insert(entry.year).inserted,
                  (1...1_000_000).contains(entry.revision),
                  entry.file == "\(entry.year).v\(entry.revision).json",
                  entry.sha256.utf8.count == 64,
                  entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw WorkdayError.invalidData("年度索引内容不正确")
            }
        }
        return value
    }
}

public struct WorkdayAlarmRule: Codable, Equatable, Identifiable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case workdays, everyday, weekly
        public var title: String {
            switch self { case .workdays: "法定工作日"; case .everyday: "每天"; case .weekly: "自选星期" }
        }
    }
    public var id: UUID
    public var hour: Int
    public var minute: Int
    public var label: String
    public var enabled: Bool
    public var mode: Mode
    /// Calendar weekday: Sunday=1, Monday=2.
    public var weekdays: Set<Int>
    public var exceptions: [String: Bool]
    public init(id: UUID = UUID(), hour: Int = 7, minute: Int = 30, label: String = "起床",
                enabled: Bool = true, mode: Mode = .workdays, weekdays: Set<Int> = [2,3,4,5,6],
                exceptions: [String: Bool] = [:]) {
        self.id = id; self.hour = hour; self.minute = minute; self.label = label
        self.enabled = enabled; self.mode = mode; self.weekdays = weekdays; self.exceptions = exceptions
    }
    public var timeText: String { String(format: "%02d:%02d", hour, minute) }
    public func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute),
              label.count <= 30, weekdays.allSatisfy({ (1...7).contains($0) }),
              mode != .weekly || !weekdays.isEmpty, exceptions.count <= 366,
              exceptions.keys.allSatisfy({ WorkdayClock.parse($0) != nil }) else {
            throw WorkdayError.scheduling("请检查时间、名称、重复星期和单日安排。")
        }
    }
}

public struct WorkdayDecision: Equatable, Sendable {
    public enum Kind: String, Sendable { case workday, makeup, holiday, weekend, selected, skipped, customOn, customOff, unknown }
    public let kind: Kind
    public let reason: String
    public let shouldRing: Bool?
}

public struct WorkdayAlarmOccurrence: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let date: Date
    public let day: String
    public let label: String
    public let reason: String
    public init(rule: WorkdayAlarmRule, date: Date, reason: String) {
        self.ruleID = rule.id; self.date = date; day = WorkdayClock.key(date)
        label = rule.label.isEmpty ? "起床" : rule.label; self.reason = reason
        let key = "workday-v1|\(rule.id)|\(day)|\(rule.timeText)|\(label)|\(reason)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                         bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

public enum WorkdayPlanner {
    public struct Plan: Sendable {
        public let occurrences: [WorkdayAlarmOccurrence]
        public let missingYears: Set<Int>
        public let budgetReached: Bool
    }
    public static func decision(day: Date, rule: WorkdayAlarmRule, datasets: [Int: HolidayDataset]) -> WorkdayDecision {
        let key = WorkdayClock.key(day)
        if let forced = rule.exceptions[key] {
            return .init(kind: forced ? .customOn : .customOff, reason: forced ? "已设为响铃" : "已设为休息", shouldRing: forced)
        }
        let weekday = WorkdayClock.calendar.component(.weekday, from: day)
        if rule.mode == .everyday { return .init(kind: .selected, reason: "每天响铃", shouldRing: true) }
        if rule.mode == .weekly {
            let selected = rule.weekdays.contains(weekday)
            return .init(kind: selected ? .selected : .skipped, reason: selected ? "自选星期" : "未选择此星期", shouldRing: selected)
        }
        let year = WorkdayClock.calendar.component(.year, from: day)
        guard let dataset = datasets[year] else {
            return .init(kind: .unknown, reason: "\(year) 年调休数据未就绪", shouldRing: nil)
        }
        if let item = dataset.override(on: key) {
            return .init(kind: item.kind == .work ? .makeup : .holiday,
                         reason: item.name, shouldRing: item.kind == .work)
        }
        let workday = (2...6).contains(weekday)
        return .init(kind: workday ? .workday : .weekend,
                     reason: workday ? "工作日" : "周末休息", shouldRing: workday)
    }
    public static func plan(rules: [WorkdayAlarmRule], datasets: [Int: HolidayDataset],
                            now: Date, horizon: Int = 90, budget: Int = 64) throws -> Plan {
        guard (1...366).contains(horizon), (1...512).contains(budget), rules.count <= 8 else {
            throw WorkdayError.scheduling("闹钟数量或排程范围超出限制。")
        }
        var ids = Set<UUID>(), times = Set<String>()
        for rule in rules {
            try rule.validate()
            guard ids.insert(rule.id).inserted else { throw WorkdayError.scheduling("闹钟标识重复。") }
            if rule.enabled && !times.insert(rule.timeText).inserted {
                throw WorkdayError.scheduling("同一时间已有启用的闹钟，请调整时间。")
            }
        }
        var result = [WorkdayAlarmOccurrence](), missing = Set<Int>()
        for offset in 0..<horizon {
            let day = WorkdayClock.day(offset, after: now)
            for rule in rules where rule.enabled {
                let fire = WorkdayClock.parse(WorkdayClock.key(day), hour: rule.hour, minute: rule.minute)!
                guard fire > now else { continue }
                let selected = decision(day: day, rule: rule, datasets: datasets)
                if selected.shouldRing == nil { missing.insert(WorkdayClock.calendar.component(.year, from: day)) }
                if selected.shouldRing == true { result.append(.init(rule: rule, date: fire, reason: selected.reason)) }
            }
        }
        result.sort { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        return Plan(occurrences: Array(result.prefix(budget)), missingYears: missing, budgetReached: result.count > budget)
    }
}
