import AppIntents
import ActivityKit
import Foundation

struct ScrollActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let phase: String
        let message: String
        let page: Int
        var paused: Bool { phase == "paused" }
        var recording: Bool { phase == "recording" }
    }
    let sessionID: String
}

struct ToggleScrollIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "卷轴"
    static let description = IntentDescription("开始滚动截图；再次点击完成并自动保存。")
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult {
        #if !SCROLLSTITCH_CONTROLS && canImport(ScreenCaptureKit)
        await ScrollCaptureCoordinator.shared.toggle()
        #else
        throw ScrollControlError.mainAppRequired
        #endif
        return .result()
    }
}
struct NextScrollPageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "卷轴 · 接下一页"
    static let description = IntentDescription("暂停换页；再次点击继续录制，无需返回卷轴。")
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult {
        #if !SCROLLSTITCH_CONTROLS && canImport(ScreenCaptureKit)
        await ScrollCaptureCoordinator.shared.nextPage()
        #else
        throw ScrollControlError.mainAppRequired
        #endif
        return .result()
    }
}
struct FinishScrollIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "完成"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    func perform() async throws -> some IntentResult {
        #if !SCROLLSTITCH_CONTROLS && canImport(ScreenCaptureKit)
        await ScrollCaptureCoordinator.shared.finish()
        #else
        throw ScrollControlError.mainAppRequired
        #endif
        return .result()
    }
}
enum ScrollControlError: Error { case mainAppRequired }
