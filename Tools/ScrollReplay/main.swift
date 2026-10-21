import Foundation
import ScrollStitchCore
import ScrollStitchImaging

private struct Corpus:Decodable {
    let version:Int
    let cases:[Item]
    struct Item:Decodable {
        let id:String,taskPath:String
        let inputs:[Input]
    }
    struct Input:Decodable {let path:String,sha256:String,bytes:Int}
}
@main struct ScrollReplay {
    private struct Baseline: Decodable {
        struct Case: Decodable {
            struct Report: Decodable { let outputPaths: [String] }
            let id: String
            let report: Report
        }
        let cases: [Case]
    }
    /// Both sides use ImageIO's decoder to avoid attributing JPEG decoder
    /// rounding differences to the stitching algorithm. Every RGBA byte counts.
    private static func verifyPixels(baseline: URL, output: URL) throws {
        let cases = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baseline)).cases
        var report: [[String: Any]] = []
        for item in cases {
            let directory = output.appendingPathComponent(item.id)
            let result = try JSONDecoder().decode(CaptureResultSet.self,
                from: Data(contentsOf: directory.appendingPathComponent("result-set.json")))
            let root = directory.appendingPathComponent("store/tasks/" + result.taskID.uuidString)
            var failures: [String] = []
            if result.pages.count != item.report.outputPaths.count { failures.append("page count differs") }
            var pixels = 0
            for (page, expected) in zip(result.pages, item.report.outputPaths) {
                try autoreleasepool {
                    let actual = try ImageDecoder.raster(page.result.path.resolved(in: root))
                    let reference = try ImageDecoder.raster(URL(fileURLWithPath: expected))
                    if actual.size != reference.size { failures.append("page geometry differs") }
                    else if actual.rgba != reference.rgba { failures.append("decoded pixels differ") }
                    pixels += actual.size.pixels
                }
            }
            report.append(["case": item.id, "passed": failures.isEmpty, "pixels": pixels, "failures": failures])
        }
        let passed = report.allSatisfy { $0["passed"] as? Bool == true }
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": report], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("pixel-parity.json"))
        guard passed else { throw ReplayError.pixelMismatch }
    }
    static func main() async {
        do {
            let args=Array(CommandLine.arguments.dropFirst())
            if args.count == 3, args[0] == "--verify-baseline" {
                try verifyPixels(baseline: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
                print("All decoded output pixels match the frozen baseline")
                return
            }
            guard args.count==2 || args.count==3 else {throw ReplayError.usage}
            let corpus=try JSONDecoder().decode(Corpus.self,from:Data(contentsOf:URL(fileURLWithPath:args[0])))
            guard corpus.version==1 else {throw ScrollStitchError.unsupportedSchema}
            let output=URL(fileURLWithPath:args[1],isDirectory:true)
            guard !FileManager.default.fileExists(atPath:output.path) else {throw ReplayError.outputExists}
            let selected=corpus.cases.filter {args.count==2 || $0.id==args[2]}
            guard !selected.isEmpty else {throw ReplayError.usage}
            for item in selected {
                let source=URL(fileURLWithPath:item.taskPath)
                for input in item.inputs {
                    let url=try AssetPath(input.path).resolved(in:source)
                    guard try TaskStore.digest(url:url)==input.sha256,
                          try url.resourceValues(forKeys:[.fileSizeKey]).fileSize==input.bytes else {
                        throw ReplayError.changedSource
                    }
                }
                let decoder=JSONDecoder();decoder.dateDecodingStrategy = .millisecondsSince1970
                let snapshot=try decoder.decode(CaptureSnapshot.self,from:Data(contentsOf:source.appendingPathComponent("capture.json")))
                try snapshot.validate()
                let directory=output.appendingPathComponent(item.id),root=directory.appendingPathComponent("store")
                let tasks=root.appendingPathComponent("tasks")
                try FileManager.default.createDirectory(at:tasks,withIntermediateDirectories:true)
                let destination=tasks.appendingPathComponent(snapshot.taskID.uuidString)
                // Copy only committed input, never previous outputs or caches.
                // The original task remains read-only throughout the replay.
                var names = ["capture.json"] + snapshot.frames.map { $0.asset.path.value }
                if FileManager.default.fileExists(atPath: source.appendingPathComponent("scroll-frames.json").path) {
                    names.append("scroll-frames.json")
                }
                for name in names {
                    let target = try AssetPath(name).resolved(in: destination)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: try AssetPath(name).resolved(in: source), to: target)
                }
                let encoder=JSONEncoder();encoder.dateEncodingStrategy = .millisecondsSince1970
                try encoder.encode(TaskManifest(taskID:snapshot.taskID,kind:.capture,now:snapshot.startedAt))
                    .write(to:root.appendingPathComponent("current.json"))
                let result=try await CapturePipeline.run(store:TaskStore(root:root),taskID:snapshot.taskID,
                    selectionFingerprint:TaskStore.digest(data:Data("pipeline-replay".utf8)))
                try JSONEncoder().encode(result.result).write(to:directory.appendingPathComponent("result-set.json"))
                let evidence:[String:Any]=["case":item.id,"seconds":result.seconds,"status":result.result.status.rawValue,
                    "pages":result.result.pages.count,"recipe":CapturePipeline.recipe,
                    "scope":"local immutable-input replay; not device capture or Photos evidence"]
                try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted])
                    .write(to:directory.appendingPathComponent("metrics.json"))
                print("\(item.id): \(result.result.status.rawValue), \(result.result.pages.count) pages, \(result.seconds) seconds")
            }
        } catch {
            FileHandle.standardError.write(Data("ScrollReplay: \(error)\n".utf8));exit(1)
        }
    }
    enum ReplayError:Error {case usage,outputExists,changedSource,pixelMismatch}
}
