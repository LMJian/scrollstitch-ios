import Foundation

/// A small display snapshot shared with the controls extension. Commands still
/// run in the main app and validate the authoritative session before acting.
enum ScrollControlPhase: String, Codable, Sendable {
    case idle, choosing, recording, paused, processing

    init(sessionPhase: String) {
        switch sessionPhase {
        case "choosing", "starting": self = .choosing
        case "recording": self = .recording
        case "pausing", "paused": self = .paused
        case "sealing", "processing", "saving": self = .processing
        default: self = .idle
        }
    }

    var title: String {
        switch self {
        case .idle: "开始截图"
        case .choosing: "确认共享"
        case .recording, .paused: "完成截图"
        case .processing: "正在整理"
        }
    }
}

enum ScrollControlState {
    static let mainKind = "local.scrollstitch.capture"
    static let pageKind = "local.scrollstitch.next-page"

    private static var url: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ScrollStitchAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/ScrollStitch/scroll-control.json")
    }

    static var current: ScrollControlPhase {
        guard let url, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ScrollControlPhase.self, from: data) else { return .idle }
        return value
    }

    static func publish(_ phase: ScrollControlPhase) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(phase).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch {
            // A display refresh never takes ownership of capture or damages a
            // work. The main app validates real state even if this is stale.
        }
    }
}
