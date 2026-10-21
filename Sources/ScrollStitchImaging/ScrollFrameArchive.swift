import Foundation
#if SWIFT_PACKAGE
import ScrollStitchCore
#endif

enum ScrollFrameStorage {
    static func outputsDirectory(in root: URL) throws -> URL {
        let value = root.appendingPathComponent("Outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
}

/// Confined to the native stream's serial sample queue. Commit first, then
/// offer derived analysis to a bounded queue. A full cache queue loses no input.
public final class ScrollFrameArchive: @unchecked Sendable {
    private let store: TaskStore
    private let taskID: UUID
    private let owner: FileLease
    private let directory: URL
    private let preprocessor = FramePreprocessor()
    private var input: ScrollFrameInput
    private var lastPTS: Double?
    private var bytes = 0
    private var sealed = false
    public private(set) var paused = false
    public private(set) var frameCount = 0
    public var page: Int { max(0, input.segmentStarts.count - 1) }

    public init(store: TaskStore, taskID: UUID, owner: FileLease,
                options: ScrollCaptureOptions, topCropRatio: Double) throws {
        self.store = store; self.taskID = taskID; self.owner = owner
        directory = try store.taskDirectory(taskID)
        input = try ScrollFrameInput(options: options, topCropRatio: topCropRatio)
        try captureWriteJSON(input, to: directory.appendingPathComponent("scroll-frames.json"))
    }

    public func accepts(pts: Double, hostForeground: Bool) -> Bool {
        !sealed && !paused && !hostForeground && pts.isFinite && pts >= 0 &&
            (lastPTS == nil || pts - lastPTS! >= 0.25)
    }

    @discardableResult
    public func append(jpeg: Data, size: PixelSize, pts: Double, hostForeground: Bool = false) throws -> Bool {
        guard accepts(pts: pts, hostForeground: hostForeground) else { return false }
        guard bytes + jpeg.count <= CaptureStorageBudget.materialBudget else { throw ScrollStitchError.budgetExceeded }
        if frameCount % 16 == 0 {
            let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            if let available, available < jpeg.count + 64 * 1024 * 1024 { throw ScrollStitchError.storageFailure }
        }
        let frame = try store.appendCapturedFrame(taskID: taskID, owner: owner, jpeg: jpeg, size: size, pts: pts)
        lastPTS = pts; frameCount += 1; bytes += jpeg.count
        preprocessor.enqueue(jpeg, for: try frame.asset.path.resolved(in: directory), options: input.options)
        return true
    }

    @discardableResult
    public func togglePage() throws -> Bool {
        guard !sealed else { throw ScrollStitchError.staleOperation }
        var next = input
        if paused {
            if frameCount > (next.segmentStarts.last ?? 0) { next.segmentStarts.append(frameCount) }
            lastPTS = nil
        }
        try next.validate(frameCount: frameCount)
        try captureWriteJSON(next, to: directory.appendingPathComponent("scroll-frames.json"))
        input = next; paused.toggle()
        return paused
    }

    public func seal() { sealed = true }

    public func finish(complete: Bool) throws {
        sealed = true
        input.complete = complete && frameCount > 0
        try input.validate(frameCount: frameCount)
        try captureWriteJSON(input, to: directory.appendingPathComponent("scroll-frames.json"))
        try store.finishCapture(taskID: taskID, owner: owner, reason: input.complete ? .userStopped : .unknown)
    }
}
