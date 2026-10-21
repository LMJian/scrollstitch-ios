import ScrollStitchCore
import Foundation

/// Bounded local startup evidence, without screen contents, URLs or error userInfo.
public final class CaptureStartupDiagnostics: @unchecked Sendable {
    private struct Event: Codable {
        let step: String
        let elapsed: Double
        let uptime: Double
        let values: [String: String]
    }
    private struct Report: Codable {
        var schemaVersion = 1
        var backend = "ScreenCaptureKit"
        let build: String
        let sessionID: UUID
        var events: [Event]
    }
    private let lock = NSLock()
    private let url: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var report: Report
    public init(directory: URL, build: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        url = directory.appendingPathComponent(id.uuidString + ".json")
        report = Report(build: build, sessionID: id, events: [])
        // Keep the latest eight attempts, never capture assets or other app data.
        let old = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in old.dropFirst(7) { try? FileManager.default.removeItem(at: file) }
    }
    public func record(_ step: String, values: [String: String] = [:], error: (any Error)? = nil) {
        lock.lock(); defer { lock.unlock() }
        var details = values
        if let error { let ns = error as NSError; details["errorDomain"] = ns.domain; details["errorCode"] = String(ns.code) }
        if report.events.count == 96 { report.events.remove(at: 1) }
        let uptime=ProcessInfo.processInfo.systemUptime
        report.events.append(Event(step: step, elapsed: uptime - started, uptime:uptime, values: details))
        do {
            let data = try JSONEncoder().encode(report)
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var file = url; try file.setResourceValues(values)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
#endif
        } catch { /* Diagnostics must never interrupt the user's capture. */ }
    }
}
