import Foundation

public struct WorkspaceSnapshot: Sendable {
    public let manifest: TaskManifest?
    public let edit: EditSnapshot?
    public let capture: CaptureSnapshot?
    public var hasCaptureMedia:Bool = false
}

/// Read the current work without migrating its container or rewriting legacy capture data.
public enum WorkspaceRecovery {
    public static func read(_ store: TaskStore, captureCreationEnabled: Bool = BuildMode.captureCreationEnabled,
                            now: Date = Date()) throws -> WorkspaceSnapshot {
        if let current = try store.current(), current.kind != .capture || captureCreationEnabled {
            _ = try store.cleanup(taskID: current.taskID, explicit: false, now: now)
        }
        guard let current = try store.current() else {
            return WorkspaceSnapshot(manifest: nil, edit: nil, capture: nil)
        }
        let capture: CaptureSnapshot?
        if current.kind == .capture {
            // Only read metadata for a legacy work. No repair, expiry or image processing.
            // A result must still pass currentResult/openResult checks before export.
            capture = captureCreationEnabled ? try store.reconcileCapture(taskID: current.taskID)
                : try store.captureSnapshot(taskID: current.taskID, verifyFiles: false)
        } else { capture = nil }
        return try WorkspaceSnapshot(manifest: current,
            edit: current.kind == .collage ? store.reconcileEdit(taskID: current.taskID) : nil,
            capture: capture,hasCaptureMedia:current.kind == .capture ? store.hasCaptureMedia(taskID:current.taskID):false)
    }
}
