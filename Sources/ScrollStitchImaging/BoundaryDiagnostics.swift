import Foundation
import CoreGraphics
import ImageIO
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public struct BoundaryDiagnosticFailure: Error {
    public let check: String
}

/// Isolated diagnostic stores only. Never pass the user's current TaskStore here.
public enum BoundaryDiagnostics {
    public static func relativePath(of file: URL, under root: URL) throws -> String {
        let base=root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components=file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else {
            throw BoundaryDiagnosticFailure(check:"diagnostic_path_outside_root")
        }
        return components.dropFirst(base.count).joined(separator:"/")
    }

    private static func require(_ condition: Bool, _ check: String) throws {
        guard condition else { throw BoundaryDiagnosticFailure(check:check) }
    }
    private static func fresh(_ root: URL) throws {
        guard !FileManager.default.fileExists(atPath:root.path) else {
            throw BoundaryDiagnosticFailure(check:"diagnostic_directory_exists")
        }
        _ = try TaskStore(root:root)
    }
    private static func protected(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        #endif
        var value=url, properties=URLResourceValues(); properties.isExcludedFromBackup=true
        try value.setResourceValues(properties)
    }
    public static func lifecycle(root: URL, check: () throws -> Void,
                                 record: ([String:String]) throws -> Void) throws {
        try fresh(root); try check()
        let source=root.appendingPathComponent("external-source.png")
        try BenchmarkFixtures.writePNG(source,width:40,height:60,offset:0,seed:1); try protected(source)
        let saved=root.appendingPathComponent("external-saved-copy.png")
        try FileManager.default.copyItem(at:source,to:saved); try protected(saved)
        let digest=try TaskStore.digest(url:source), origin=Date(timeIntervalSince1970:1_800_000_000)
        // Advance only injected clocks in isolated stores, never the device clock or current task.
        let ttl=try TaskStore(root:root.appendingPathComponent("ttl"))
        let task=try ttl.createCollage(now:origin)
        _ = try ImageImporter.ingest(source,store:ttl,taskID:task.taskID)
        try require(try !ttl.cleanup(taskID:task.taskID,explicit:false,now:origin.addingTimeInterval(86_399)),"ttl_before_boundary")
        _ = try ttl.current(); _ = try ttl.editSnapshot(taskID:task.taskID)
        try require(try ttl.current()?.lastInteractionAt == origin,"read_extended_ttl")
        try require(try ttl.cleanup(taskID:task.taskID,explicit:false,now:origin.addingTimeInterval(86_400)),"ttl_at_boundary")
        try require(try ttl.current() == nil,"ttl_current_not_removed")
        try require(try TaskStore.digest(url:source) == digest && TaskStore.digest(url:saved) == digest,"external_files_changed")
        try record(["id":"ttl_boundary_and_external_files","status":"pass","scope":"Injected 86399/86400 seconds; external synthetic copies, not Photos-library deletion."])
        try check()
        let renew=try TaskStore(root:root.appendingPathComponent("renewal"))
        let renewed=try renew.createCollage(now:origin)
        try renew.recordInteraction(taskID:renewed.taskID,now:origin.addingTimeInterval(60))
        try require(try !renew.cleanup(taskID:renewed.taskID,explicit:false,now:origin.addingTimeInterval(86_400)),"interaction_not_renewed")
        try require(try renew.cleanup(taskID:renewed.taskID,explicit:false,now:origin.addingTimeInterval(86_460)),"renewed_boundary")
        try record(["id":"explicit_interaction_renews_ttl","status":"pass","scope":"Injected clock; no 24-hour wall-clock wait."])
        try check()
        let shared=try TaskStore(root:root.appendingPathComponent("shared"))
        let sharedTask=try shared.createCollage(now:origin)
        var share: FileLease?=try shared.acquireShareLease(taskID:sharedTask.taskID)
        try withExtendedLifetime(share) {
            try require(try !shared.cleanup(taskID:sharedTask.taskID,explicit:false,now:origin.addingTimeInterval(86_400)),"share_lease_deleted")
            try require(try shared.current()?.pendingCleanup == true,"share_pending_missing")
        }
        share=nil
        try require(try shared.cleanup(taskID:sharedTask.taskID,explicit:false,now:origin),"share_pending_not_retried")
        try record(["id":"share_lease_defers_cleanup","status":"pass","scope":"Real local file lease in isolated device store; pending cleanup after release."])
        try check()
        let active=try TaskStore(root:root.appendingPathComponent("active"))
        var capture: (TaskManifest,FileLease)?=try active.beginCapture(now:origin)
        let id=capture!.0.taskID
        _ = try active.appendFrame(taskID:id,owner:capture!.1,png:Data(contentsOf:source),size:PixelSize(width:40,height:60),pts:1)
        try withExtendedLifetime(capture) {
            try require(try active.reconcileCapture(taskID:id).phase == .reconciling,"active_lease_not_unknown")
            try require(try !active.cleanup(taskID:id,explicit:true,now:origin.addingTimeInterval(100_000)),"active_lease_deleted")
            try require(try active.captureSnapshot(taskID:id).frames.count == 1,"active_frame_changed")
        }
        capture=nil
        let recovered=try active.reconcileCapture(taskID:id)
        try require(recovered.phase == .interrupted && recovered.endReason == .ownerLost && recovered.frames.count == 1,"owner_loss_not_recovered")
        try require(try !active.cleanup(taskID:id,explicit:false,now:origin),"recorded_work_expired")
        try require(try active.cleanup(taskID:id,explicit:true,now:origin),"explicit_cleanup_failed")
        try record(["id":"unknown_active_lease_preserves_frame","status":"pass","scope":"Same-process independent flock handles; not a new ReplayKit process-kill run."])
        try check()
        let failed=try TaskStore(root:root.appendingPathComponent("write-failure"),fault:{ point in
            if point == .afterAssetWrite { throw ScrollStitchError.storageFailure }
        })
        var attempt:(TaskManifest,FileLease)?=try failed.beginCapture()
        let failedID=attempt!.0.taskID
        var observed=false
        do {
            _ = try failed.appendFrame(taskID:failedID,owner:attempt!.1,png:Data(contentsOf:source),
                size:PixelSize(width:40,height:60),pts:1)
        } catch ScrollStitchError.storageFailure {
            observed=true
            try failed.finishCapture(taskID:failedID,owner:attempt!.1,reason:.writeFailure)
        }
        attempt=nil
        try require(observed,"write_failure_not_observed")
        let failure=try failed.reconcileCapture(taskID:failedID)
        let directory=try failed.taskDirectory(failedID)
        try require(failure.frames.isEmpty && failure.endReason == .writeFailure,"write_failure_published_frame")
        for folder in ["temporary","assets"] {
            try require(try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent(folder).path).isEmpty,"write_failure_left_asset")
        }
        try require(try TaskStore.digest(url:source) == digest,"failure_changed_source")
        try record(["id":"injected_capture_write_failure","status":"pass","scope":"Injected storageFailure after temp write; NOT actual OS low-disk or memory pressure."])
    }

    /// Includes fixture preparation and import, followed by one synthetic JPEG render.
    public static func twenty48MP(root: URL, check: () throws -> Void, cancelled: () -> Bool = { false },
                                  progress: (Int) throws -> Void) throws -> [String:Any] {
        try fresh(root)
        let store=try TaskStore(root:root.appendingPathComponent("store")), task=try store.createCollage()
        let source=root.appendingPathComponent("fixture.png")
        var assets=[SourceAsset]()
        for index in 0..<20 {
            try check()
            try autoreleasepool {
                try BenchmarkFixtures.writePNG(source,width:6000,height:8000,offset:0,seed:100+index,cancelled:cancelled)
                try protected(source)
                let asset=try ImageImporter.ingest(source,store:store,taskID:task.taskID)
                try require(asset.size.pixels == 48_000_000,"48mp_input_dimensions")
                assets.append(asset)
            }
            try progress(index+1)
        }
        try FileManager.default.removeItem(at:source); try check()
        let edit=try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:assets),expectedRevision:0)
        guard case .requiresConsent(let width,let height,let plan)=try LayoutEngine.propose(taskID:task.taskID,
            revision:edit.revision,inputs:assets.map { LayoutInput(asset:$0) }) else {
            throw BoundaryDiagnosticFailure(check:"48mp_expected_downscale_proposal")
        }
        // Independent integer oracle: 20 * roundHalfUp(8000*948/6000) = 25280.
        // 948*25280 = 23965440; width949 would require 24009700 pixels (>24MP).
        try require(width == 1080 && height == 28800 && plan.size.width == 948 && plan.size.height == 25280,
                    "48mp_downscale_geometry")
        try require(plan.items.count == 20 && plan.items.map(\.input.asset.id) == assets.map(\.id),"48mp_order_or_count")
        let artifact=try ImageRenderer.render(plan,store:store,format:.jpeg,cancelled:cancelled)
        let decoded=try ImageDecoder.normalized(artifact.url,maxDimension:1600)
        try require(decoded.width > 0 && decoded.height == 1600,"48mp_preview_decode")
        return ["input_count":20,"source_pixels_each":48000000,"fixture_manifest":assets.map {
            ["sha256":$0.sha256,"width":$0.size.width,"height":$0.size.height] as [String:Any] },
            "requested_width":width,"requested_height":height,"width":artifact.size.width,"height":artifact.size.height,
            "output_sha256":artifact.sha256,"output_bytes":artifact.sizeBytes,"jpeg_quality":ImageRenderer.jpegQuality,
            "downscale_consent":"Diagnostic accepts the known proposal only for synthetic isolated sources; no user-task setting changed.",
            "scope":"20 distinct synthetic 48MP local PNGs through production importer/layout/renderer; not Photos-provider selection, photographic entropy or 30-trial performance."]
    }
}
