#if !SCROLLSTITCH_COLLAGE_ONLY && canImport(ScreenCaptureKit)
import Foundation
@preconcurrency import BackgroundTasks

@MainActor enum ScrollBackground {
    static var identifier:String {(Bundle.main.bundleIdentifier ?? "local.scrollstitch.app")+".finish-scroll"}
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier:identifier,using:.main) { task in
            guard let processing=task as? BGProcessingTask else {task.setTaskCompleted(success:false);return}
            Task { @MainActor in await ScrollCaptureCoordinator.shared.resumeBackground(processing) }
        }
    }
    /// Scheduling is opportunistic; it does not promise an immediate execution
    /// window. The foreground/user-intent path starts work immediately.
    static func enqueue() throws {
        let request=BGProcessingTaskRequest(identifier:identifier)
        request.requiresNetworkConnectivity=false;request.requiresExternalPower=false
        try BGTaskScheduler.shared.submit(request)
    }
    static func cancel() {BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier)}
}
#endif
