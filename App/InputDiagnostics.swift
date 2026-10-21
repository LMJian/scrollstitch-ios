import Foundation
import Network
import ImageIO
import UniformTypeIdentifiers

struct InputDiagnosticResult: Sendable {
    let complete: Bool
    let stopReason: String
    let offlineVerified: Bool
}
private struct DiagnosticPathObservation: Codable, Equatable {
    let status: String
    let usedInterfaceTypes: [String]
    let availableInterfaces: [String]
}
private final class DiagnosticNetworkState: @unchecked Sendable {
    private let lock=NSLock()
    private let monitor=NWPathMonitor()
    private var history=[String]()
    private var observations=[DiagnosticPathObservation]()
    init() {
        monitor.pathUpdateHandler={ [weak self] path in
            let state: String
            switch path.status {
            case .satisfied: state="satisfied"
            case .unsatisfied: state="unsatisfied"
            case .requiresConnection: state="requiresConnection"
            @unknown default: state="unknown"
            }
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            let types:[NWInterface.InterfaceType]=[.wifi,.cellular,.wiredEthernet,.loopback,.other]
            let observation=DiagnosticPathObservation(status:state,
                usedInterfaceTypes:types.filter {path.usesInterfaceType($0)}.map {String(describing:$0)},
                availableInterfaces:path.availableInterfaces.map { $0.name+":"+String(describing:$0.type) })
            if self.observations.last != observation, self.observations.count < 128 { self.observations.append(observation) }
            if self.history.last != state {
                if self.history.count < 128 { self.history.append(state) }
                else if self.history.last != "history_overflow" { self.history.append("history_overflow") }
            }
        }
        monitor.start(queue:DispatchQueue(label:"ScrollStitch.diagnostic-path"))
    }
    func states() -> [String] { lock.lock(); defer { lock.unlock() }; return history }
    func details() throws -> Any {
        lock.lock(); let snapshot=observations; lock.unlock()
        return try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot))
    }
    deinit { monitor.pathUpdateHandler=nil; monitor.cancel() }
}

enum InputDiagnostics {
    private static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw BoundaryDiagnosticFailure(check:code) }
    }
    private static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        #endif
        var value=url, flags=URLResourceValues();flags.isExcludedFromBackup=true;try value.setResourceValues(flags)
    }
    private static func write(_ report: [String:Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)
        try protect(url)
    }
    private static func provider(_ url: URL, _ type: UTType, _ id: String) -> PickerInput {
        let item=NSItemProvider()
        item.registerFileRepresentation(forTypeIdentifier:type.identifier,fileOptions:[],visibility:.all) { completion in
            completion(url,false,nil); return nil
        }
        return PickerInput(id:UUID(),identifier:id,provider:item)
    }
    static func run(store: TaskStore, cancellation: WorkCancellation, buildRevision: String,
                    requireOffline: Bool = true) async throws -> InputDiagnosticResult {
        #if targetEnvironment(simulator)
        throw BoundaryDiagnosticFailure(check:"physical_device_required")
        #endif
        let guards=try store.acquireDiagnosticLease()
        defer { withExtendedLifetime(guards) {} }
        let runID=UUID().uuidString
        let directory=store.root.appendingPathComponent("input-diagnostics/"+runID)
        try require(!FileManager.default.fileExists(atPath:directory.path),"diagnostic_directory_exists")
        let isolated=try TaskStore(root:directory.appendingPathComponent("store"));try protect(directory)
        let reportURL=directory.appendingPathComponent("report.json")
        #if os(iOS)
        let deviceKind="physical"
        #else
        let deviceKind="host"
        #endif
        var report:[String:Any] = ["schema_version":1,"run_id":runID,"commit":buildRevision,"device_kind":deviceKind,
            "started_at":ISO8601DateFormatter().string(from:Date()),"decision":"partial","progress":"preflight",
            "requires_offline":requireOffline,"run_mode":requireOffline ? "input_and_offline" : "local_input_only","checks":[[String:Any]](),
            "scope":"Self-authored NSItemProvider representations through the actual picker batch loader; not PHPicker selection UI or iCloud service testing. NWPathMonitor observes route state without making network requests; this is not a no-upload audit."]
        try write(report,reportURL)
        var checks=[[String:Any]]()
        func record(_ value: [String:Any]) throws { checks.append(value);report["checks"]=checks;try write(report,reportURL) }
        let network=DiagnosticNetworkState()
        do {
            #if os(iOS)
            try require(buildRevision.count == 40 && buildRevision.allSatisfy(\.isHexDigit),"unbound_build")
            #endif
            for _ in 0..<30 {
                try cancellation.check()
                if !network.states().isEmpty { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            let initial=network.states();report["network_states_start"]=initial
            report["network_path_observations"]=try network.details();try write(report,reportURL)
            if requireOffline { try require(initial == ["unsatisfied"],"offline_required") }
            let first=directory.appendingPathComponent("first.png"), last=directory.appendingPathComponent("last.png")
            try BenchmarkFixtures.writePNG(first,width:640,height:480,offset:0,seed:301,cancelled:{cancellation.isCancelled})
            try BenchmarkFixtures.writePNG(last,width:640,height:480,offset:0,seed:302,cancelled:{cancellation.isCancelled})
            let broken=directory.appendingPathComponent("broken.png"), gif=directory.appendingPathComponent("unsupported.gif")
            try Data([137,80,78,71,13,10,26,10]).write(to:broken)
            guard let source=CGImageSourceCreateWithURL(first as CFURL,nil),
                  let image=CGImageSourceCreateImageAtIndex(source,0,nil),
                  let writer=CGImageDestinationCreateWithURL(gif as CFURL,UTType.gif.identifier as CFString,1,nil) else {
                throw BoundaryDiagnosticFailure(check:"gif_fixture_creation_failed")
            }
            CGImageDestinationAddImage(writer,image,nil)
            try require(CGImageDestinationFinalize(writer),"gif_fixture_finalize_failed")
            for url in [first,last,broken,gif] { try protect(url) }
            guard let gifSource=CGImageSourceCreateWithURL(gif as CFURL,nil) else { throw BoundaryDiagnosticFailure(check:"gif_fixture_invalid") }
            try require(CGImageSourceGetType(gifSource) as String? == UTType.gif.identifier,"gif_fixture_wrong_type")
            let inputs=[provider(first,.png,"first"),provider(broken,.png,"corrupt"),provider(gif,.gif,"unsupported"),provider(last,.png,"last")]
            report["progress"]="provider_import";try write(report,reportURL)
            let task=try await PickerBatchLoader.ingest(inputs,store:isolated,interactionAt:Date(),cancellation:cancellation)
            try cancellation.check()
            var edit=try isolated.editSnapshot(taskID:task.taskID)
            try require(edit.imports.map(\.selectionIdentifier) == ["first","corrupt","unsupported","last"],"import_order_failed")
            try require(edit.assets.count == 2 && edit.unresolvedImports == 2,"failed_slots_missing")
            try require(edit.imports[0].asset != nil && edit.imports[3].asset != nil,"valid_sources_unavailable")
            for index in [1,2] {
                try require(edit.imports[index].asset == nil && edit.imports[index].issue != nil,"failed_slot_ready")
            }
            let expected=[try TaskStore.digest(url:first),try TaskStore.digest(url:last)]
            try require(edit.assets.map(\.sha256) == expected,"valid_source_order_changed")
            try record(["id":"corrupt_provider_input","status":"pass","failed_index":1,"ready_count":2,"unresolved_count":2])
            try record(["id":"unsupported_gif_provider_input","status":"pass","failed_index":2,"ready_count":2,"unresolved_count":2])
            guard case .ready(let unsafePlan)=try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,
                inputs:edit.assets.map { LayoutInput(asset:$0) }) else { throw BoundaryDiagnosticFailure(check:"diagnostic_geometry") }
            var blocked=false
            do { _=try ImageRenderer.render(unsafePlan,store:isolated,format:.png) }
            catch ScrollStitchError.invalidSelection { blocked=true }
            try require(blocked,"unresolved_import_render_not_blocked")
            let taskDirectory=try isolated.taskDirectory(task.taskID)
            try require(try FileManager.default.contentsOfDirectory(atPath:taskDirectory.appendingPathComponent("exports").path).isEmpty,"failed_render_published_file")
            try record(["id":"unresolved_items_block_generation","status":"pass"])
            edit.imports.removeAll { $0.asset == nil };edit.assets=edit.imports.compactMap(\.asset)
            edit=try isolated.commitEdit(edit,expectedRevision:edit.revision)
            try require(edit.unresolvedImports == 0 && edit.assets.count == 2,"failure_removal_incomplete")
            guard case .ready(let plan)=try LayoutEngine.propose(taskID:task.taskID,revision:edit.revision,
                inputs:edit.assets.map { LayoutInput(asset:$0) }), plan.size.width == 640, plan.size.height == 960 else {
                throw BoundaryDiagnosticFailure(check:"offline_layout_oracle")
            }
            var outputs=[[String:Any]]()
            for format in ImageFormat.allCases {
                let artifact=try ImageRenderer.render(plan,store:isolated,format:format,cancelled:{cancellation.isCancelled})
                let image=try ImageDecoder.normalized(artifact.url,maxDimension:1600)
                try require(image.width == 640 && image.height == 960,"offline_output_decode")
                outputs.append(["format":format.rawValue,"width":640,"height":960,"sha256":artifact.sha256,"bytes":artifact.sizeBytes])
            }
            let final=network.states();report["network_states_end"]=final
            report["network_path_observations"]=try network.details()
            if requireOffline { try require(!final.isEmpty && final.allSatisfy {$0 == "unsatisfied"},"network_changed_during_diagnostic") }
            try record(["id":"remove_failed_inputs_and_local_render","status":"pass","offline_observed":requireOffline,
                "outputs":outputs,"source_hashes":expected])
            // Exercise the corrected formatter without another 60-round run.
            let paths=try [first,last,broken,gif,reportURL].map { try BoundaryDiagnostics.relativePath(of:$0,under:store.root) }
            try require(paths.allSatisfy {$0.hasPrefix("input-diagnostics/")},"diagnostic_path_prefix_failed")
            report["relative_paths"]=paths;report["decision"]="verified_not_accepted";report["progress"]="complete"
            report["completed_at"]=ISO8601DateFormatter().string(from:Date());try write(report,reportURL)
            return InputDiagnosticResult(complete:true,stopReason:"none",offlineVerified:requireOffline)
        } catch {
            let code=(error as? BoundaryDiagnosticFailure)?.check ?? (error as? ScrollStitchError).map {String(describing:$0)} ?? "system_error"
            report["progress"]="stopped";report["stop_reason"]=code;report["network_states_end"]=network.states()
            report["network_path_observations"]=try network.details();try write(report,reportURL)
            return InputDiagnosticResult(complete:false,stopReason:code,offlineVerified:false)
        }
    }
}
