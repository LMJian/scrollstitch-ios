import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import Darwin
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

public enum CaptureProcessingError: Error, LocalizedError {
    case invalid(String), deadline
    public var errorDescription:String? {
        switch self {
        case .invalid(let detail): return "本次整理未完成，原始素材仍在。\(detail)"
        case .deadline: return "整理已达到本轮时间预算，原始素材和进度已保留。"
        }
    }
}

func captureWriteJSON<T:Encodable>(_ value:T,to url:URL) throws {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    try encoder.encode(value).write(to:url,options:.atomic)
    try protectCaptureFile(url)
    let file=try FileHandle(forWritingTo:url);defer {try? file.close()};try file.synchronize()
}
func protectCaptureFile(_ url:URL) throws {
    var value=url,keys=URLResourceValues();keys.isExcludedFromBackup=true;try value.setResourceValues(keys)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
    #endif
}
func captureWriteImage(_ image:CGImage,to url:URL) throws {
    guard let writer=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else { throw ScrollStitchError.storageFailure }
    CGImageDestinationAddImage(writer,image,nil)
    guard CGImageDestinationFinalize(writer) else { throw ScrollStitchError.storageFailure }
    try protectCaptureFile(url)
}

func requireCaptureDiskBudget(_ directory:URL,additionalBytes:Int) throws {
    guard additionalBytes>=0,try CaptureStorageBudget.diskBytes(in:directory)<=CaptureStorageBudget.taskBudget-additionalBytes else {throw ScrollStitchError.budgetExceeded}
    let space=try directory.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity
    if let space,space<additionalBytes+8*1024*1024 {throw ScrollStitchError.storageFailure}
}

public struct CapturePipelineOutput:Sendable {
    public let result:CaptureResultSet
    public let seconds:Double
}
/// Processes committed screen frames. Native recording never enters a video
/// decoder, and analysis caches are optional derived data.
public enum CapturePipeline {
    public static let recipe = TaskStore.digest(data: Data("screen-frame-stitch-1".utf8))
    /// Preserve successful result IDs and their Photos ledger, but recompute a
    /// failed attempt even when it was produced by the current algorithm.
    public static func resume(store: TaskStore, taskID: UUID, selectionFingerprint: String,
                              cancelled: @escaping @Sendable () -> Bool = { false },
                              progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CaptureResultSet {
        if cancelled() { throw ScrollStitchError.cancelled }
        if let saved = try store.captureResultSet(taskID: taskID, selectionFingerprint: selectionFingerprint),
           saved.readyForPhotoSave { return saved }
        return try await run(store: store, taskID: taskID, selectionFingerprint: selectionFingerprint,
                             cancelled: cancelled, progress: progress).result
    }
    public static func run(store: TaskStore, taskID: UUID, selectionFingerprint: String,
                           format: ImageFormat = .jpeg, workBudget: Double? = nil,
                           cancelled: @escaping @Sendable () -> Bool = { false },
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CapturePipelineOutput {
        let began = ProcessInfo.processInfo.systemUptime
        if let workBudget, !workBudget.isFinite || workBudget <= 0 { throw ScrollStitchError.budgetExceeded }
        let deadline = workBudget.map { began + $0 } ?? .infinity
        let check: () throws -> Void = {
            if cancelled() { throw ScrollStitchError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw CaptureProcessingError.deadline }
        }
        let lease = try store.acquireShareLease(taskID: taskID)
        defer { withExtendedLifetime(lease) {} }
        let snapshot = try store.reconcileCapture(taskID: taskID)
        guard snapshot.phase == .ended || snapshot.phase == .interrupted else { throw ScrollStitchError.captureActive }
        let directory = try store.taskDirectory(taskID)
        let verified = try store.captureSnapshot(taskID: taskID, verifyFiles: true)
        guard verified.sequence == snapshot.sequence else { throw ScrollStitchError.staleOperation }
        let settingsURL = directory.appendingPathComponent("scroll-frames.json")
        var identityBytes = try Data(contentsOf: directory.appendingPathComponent("capture.json"))
        let input: ScrollFrameInput
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL); identityBytes.append(data)
            input = try JSONDecoder().decode(ScrollFrameInput.self, from: data)
        } else {
            var value = try ScrollFrameInput(options: ScrollCaptureOptions(), topCropRatio: 0.075)
            value.complete = snapshot.phase == .ended; input = value
        }
        try input.validate(frameCount: snapshot.frames.count)
        let sealedComplete = input.complete && snapshot.phase == .ended
        let identity = TaskStore.digest(data: identityBytes)
        let run = directory.appendingPathComponent("temporary/frame-stitch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        let engine = FrameStitcher(options: input.options)
        engine.check = check
        engine.willRenderPage = { try requireCaptureDiskBudget(directory, additionalBytes: 24_000_000 * 4) }
        let urls = try snapshot.frames.map { try $0.asset.path.resolved(in: directory) }
        progress("正在整理长图…")
        let stitched: StitchResult
        do {
            try check()
            stitched = try engine.stitch(frameURLs: urls, sessionURL: run,
                                         topCropRatio: input.topCropRatio, segmentStarts: input.segmentStarts)
        } catch let error as StitchError {
            let status: CaptureAssemblyStatus
            switch error {
            case .notEnoughFrames, .noUsableMovement: status = .noUsableContent
            default: status = .recoverableFailure
            }
            let set = CaptureResultSet(taskID: taskID, revision: snapshot.sequence, sourceIdentity: identity,
                recipe: recipe, selectionFingerprint: selectionFingerprint,
                status: sealedComplete ? status : .recoverableFailure, pages: [], gaps: [error.localizedDescription])
            try store.publishCaptureResultSet(set, using: lease)
            return CapturePipelineOutput(result: set, seconds: ProcessInfo.processInfo.systemUptime - began)
        }
        let complete = sealedComplete && !stitched.omittedOccludedBottomRows
        var pages: [CaptureResultPage] = []
        for (page, source) in stitched.outputURLs.enumerated() {
            try check()
            try requireCaptureDiskBudget(directory, additionalBytes: format == .png ? 24_000_000 * 4 :
                (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
            let key = TaskStore.digest(data: Data("\(identity)|\(recipe)|\(page)|\(format.rawValue)".utf8))
            let name = key + "." + format.rawValue
            let temporary = run.appendingPathComponent(name)
            if format == .jpeg { try FileManager.default.copyItem(at: source, to: temporary) }
            else {
                try autoreleasepool { try captureWriteImage(ImageDecoder.normalized(source), to: temporary) }
            }
            try protectCaptureFile(temporary)
            let path = try AssetPath("exports/" + name), target = try path.resolved(in: directory)
            let digest = try TaskStore.digest(url: temporary)
            let info = try ImageImporter.inspect(temporary)
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard try store.captureSnapshot(taskID: taskID, verifyFiles: false).sequence == snapshot.sequence else {
                throw ScrollStitchError.staleOperation
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                guard try TaskStore.digest(url: target) == digest else { throw ScrollStitchError.staleOperation }
            } else { try FileManager.default.moveItem(at: temporary, to: target) }
            var result = ResultManifest(taskID: taskID, revision: snapshot.sequence, selectionFingerprint: key,
                path: path, format: format.rawValue, size: info.size, sizeBytes: size, sha256: digest)
            if !complete { result.completenessNote = "素材被中断或仍有遮挡，当前结果不能确认完整，原始画面已保留。" }
            pages.append(CaptureResultPage(sourceIdentity: identity, recipe: recipe, document: 0, page: page, result: result))
        }
        struct Diagnostic: Encodable {
            let recipe: String
            let positions: [Int: Int]
            let panels: [Int]
            let accepted: Int
            let skipped: Int
            let preparedFrames: Int
            let preparedAlignments: Int
            let timings: StitchTimings
            let omittedOccludedBottomRows: Bool
        }
        try captureWriteJSON(Diagnostic(recipe: recipe, positions: engine.positions,
            panels: engine.classifiedPanels.sorted(), accepted: stitched.acceptedFrameCount,
            skipped: stitched.skippedFrameCount, preparedFrames: stitched.preparedFrameCount,
            preparedAlignments: stitched.preparedAlignmentCount, timings: stitched.timings,
            omittedOccludedBottomRows: stitched.omittedOccludedBottomRows),
            to: directory.appendingPathComponent("capture-analysis.json"))
        let set = CaptureResultSet(taskID: taskID, revision: snapshot.sequence, sourceIdentity: identity,
            recipe: recipe, selectionFingerprint: selectionFingerprint, status: complete ? .complete : .recoverableFailure,
            pages: pages, gaps: complete ? [] : ["素材被中断或部分区域仍被遮挡，无法确认完整。"])
        try check(); try store.publishCaptureResultSet(set, using: lease)
        return CapturePipelineOutput(result: set, seconds: ProcessInfo.processInfo.systemUptime - began)
    }
}
