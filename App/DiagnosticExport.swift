import SwiftUI
import UIKit
import Darwin

/// Keeps the task alive until the user closes the system activity sheet.
final class DiagnosticExport: @unchecked Sendable, Identifiable {
    let id = UUID()
    let url: URL
    private let lease: FileLease
    init(url: URL, lease: FileLease) { self.url = url; self.lease = lease }
    deinit { try? FileManager.default.removeItem(at:url); withExtendedLifetime(lease) {} }
    static func create(store: TaskStore, taskID: UUID, lastStage: String, errorCode: String, renderSeconds: Double?) throws -> DiagnosticExport {
        let lease = try store.acquireShareLease(taskID:taskID)
        let directory = try store.taskDirectory(taskID)
        guard let manifest = try store.current(), manifest.taskID == taskID else { throw ScrollStitchError.staleOperation }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        var bytes: Int64 = 0
        if let iterator = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey]) {
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
                if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            }
        }
        var report: [String:Any] = [
            "schema_version":2, "observed_at":ISO8601DateFormatter().string(from:Date()),
            "os_version":ProcessInfo.processInfo.operatingSystemVersionString,
            "task_kind":manifest.kind.rawValue, "stage":lastStage, "last_error_code":errorCode,
            "process_lifetime_max_rss_bytes":usage.ru_maxrss, "task_storage_bytes":bytes,
            "thermal_state":ProcessInfo.processInfo.thermalState.rawValue,
            "measurement_scope":"main_app_process; not extension memory; not a M0 acceptance report"
        ]
        if let renderSeconds { report["last_render_elapsed_seconds"] = renderSeconds }
        if manifest.kind == .capture {
            let capture = BuildMode.captureCreationEnabled ? try store.reconcileCapture(taskID:taskID)
                : try store.captureSnapshot(taskID:taskID,verifyFiles:false)
            report["frame_count"] = capture.frames.count; report["capture_phase"] = capture.phase.rawValue
            report["capture_end_reason"] = capture.endReason?.rawValue ?? "pending"
            let firstPTS=capture.frames.first?.monotonicPTS ?? 0
            report["frames"] = capture.frames.map { ["ordinal":$0.ordinal,"elapsed_seconds":max(0,$0.monotonicPTS-firstPTS),
                "width":$0.asset.size.width,"height":$0.asset.size.height,"sha256":$0.asset.sha256] as [String:Any] }
        } else {
            let edit = try store.editSnapshot(taskID:taskID)
            report["image_count"] = edit.assets.count; report["unfinished_count"] = edit.unresolvedImports
            report["revision"] = edit.revision
            report["images"] = edit.assets.enumerated().map { index, asset in
                ["ordinal":index,"width":asset.size.width,"height":asset.size.height,"sha256":asset.sha256] as [String:Any]
            }
        }
        let url = try AssetPath("temporary/diagnostic-" + UUID().uuidString + ".json").resolved(in:directory)
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        var protected = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        return DiagnosticExport(url:url,lease:lease)
    }
}
struct DiagnosticActivity: UIViewControllerRepresentable {
    let export: DiagnosticExport
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems:[export.url],applicationActivities:nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
