import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct InputDiagnosticSmoke {
    static func fileDigests(_ root: URL) throws -> [String:String] {
        var result=[String:String]()
        let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])!
        for case let url as URL in files where try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
            result[url.path]=try TaskStore.digest(url:url)
        }
        return result
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a fresh artifact directory") }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath:root.path) else { fatalError("Refuse to overwrite artifacts") }
        let store=try TaskStore(root:root.appendingPathComponent("store"))
        let cancellation=WorkCancellation()
        var rejected=false
        do { _=try await PickerBatchLoader.ingest([],store:store,interactionAt:Date(),cancellation:cancellation) }
        catch ScrollStitchError.invalidSelection { rejected=true }
        guard rejected, try store.current() == nil else { fatalError("Invalid selection created a task") }
        let source=root.appendingPathComponent("preserved-source.png")
        try BenchmarkFixtures.writePNG(source,width:40,height:60,offset:0,seed:7)
        let task=try store.createCollage()
        let asset=try ImageImporter.ingest(source,store:store,taskID:task.taskID)
        _=try store.commitEdit(EditSnapshot(taskID:task.taskID,assets:[asset]),expectedRevision:0)
        let before=try fileDigests(root)
        let result=try await InputDiagnostics.run(store:store,cancellation:cancellation,buildRevision:"host-smoke",requireOffline:false)
        guard result.complete, !result.offlineVerified else { fatalError("Local-only diagnostic failed or falsely claimed offline: \(result.stopReason)") }
        guard try store.current()?.taskID == task.taskID else { fatalError("Diagnostic changed the current task") }
        for (path,hash) in before {
            guard try TaskStore.digest(url:URL(fileURLWithPath:path)) == hash else { fatalError("Existing file changed") }
        }
        let runs=try FileManager.default.contentsOfDirectory(at:store.root.appendingPathComponent("input-diagnostics"),includingPropertiesForKeys:nil)
        guard runs.count == 1 else { fatalError("Unexpected diagnostic run count") }
        let report=try JSONSerialization.jsonObject(with:Data(contentsOf:runs[0].appendingPathComponent("report.json"))) as! [String:Any]
        guard report["device_kind"] as? String == "host",report["progress"] as? String == "complete",
              report["requires_offline"] as? Bool == false,
              report["run_mode"] as? String == "local_input_only",
              !(report["network_path_observations"] as? [[String:Any]] ?? []).isEmpty,
              (report["checks"] as? [[String:Any]])?.count == 4 else { fatalError("Unexpected report") }
        let isolated=try TaskStore(root:runs[0].appendingPathComponent("store"))
        let diagnosticTask=try isolated.current()!, edit=try isolated.editSnapshot(taskID:diagnosticTask.taskID)
        guard edit.imports.map(\.selectionIdentifier) == ["first","last"],edit.unresolvedImports == 0 else {
            fatalError("Failure removal lost source order")
        }
        let exports=try FileManager.default.contentsOfDirectory(at:isolated.taskDirectory(diagnosticTask.taskID).appendingPathComponent("exports"),includingPropertiesForKeys:nil)
        guard exports.count == 2 else { fatalError("Unexpected export count") }
        for url in exports {
            guard let imageSource=CGImageSourceCreateWithURL(url as CFURL,nil),
                  let image=CGImageSourceCreateImageAtIndex(imageSource,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
                  image.width == 640,image.height == 960 else { fatalError("Full output decode failed") }
        }
        // Controlled memory cancellation during a real provider request. This is not OS pressure.
        let pressureStore=try TaskStore(root:root.appendingPathComponent("controlled-memory-store"))
        let pressureFlag=WorkCancellation(), pendingProgress=Progress(totalUnitCount:1)
        let first=NSItemProvider(), pending=NSItemProvider(), later=NSItemProvider()
        first.registerFileRepresentation(forTypeIdentifier:UTType.png.identifier,fileOptions:[],visibility:.all) { completion in
            completion(source,false,nil); return nil
        }
        pending.registerFileRepresentation(forTypeIdentifier:UTType.png.identifier,fileOptions:[],visibility:.all) { completion in
            pressureFlag.cancel(reason:.memoryPressure)
            pressureFlag.cancel() // A late UI cancellation must not replace the first cause.
            completion(source,false,nil) // A late successful provider must not publish another asset.
            return pendingProgress
        }
        later.registerFileRepresentation(forTypeIdentifier:UTType.png.identifier,fileOptions:[],visibility:.all) { _ in
            fatalError("Provider after memory cancellation must not start")
        }
        let stoppedTask=try await PickerBatchLoader.ingest([first,pending,later].enumerated().map {
            PickerInput(id:UUID(),identifier:"memory-\($0.offset)",provider:$0.element)
        },store:pressureStore,interactionAt:Date(),cancellation:pressureFlag)
        let stoppedEdit=try pressureStore.editSnapshot(taskID:stoppedTask.taskID)
        guard pressureFlag.reason == .memoryPressure, pendingProgress.isCancelled,
              stoppedEdit.assets.count == 1, stoppedEdit.unresolvedImports == 2,
              stoppedEdit.imports[1].issue == .cancelled,
              try TaskStore.digest(url:pressureStore.assetURL(stoppedEdit.assets[0],taskID:stoppedTask.taskID)) == TaskStore.digest(url:source)
        else { fatalError("Memory cancellation lost prefix, cause or unresolved state") }
        for (path,hash) in before {
            guard try TaskStore.digest(url:URL(fileURLWithPath:path)) == hash else { fatalError("Pressure probe changed original data") }
        }
        print("PASS controlled memory cancellation: first imported image retained; pending request cancelled; late success rejected; next provider not started. NOT OS-pressure evidence.")
        print("PASS host provider smoke: corrupt/unsupported slots, generation blocked, failure removal, PNG/JPEG640x960, current task and \(before.count) files preserved. NOT phone/offline evidence.")
    }
}
