import ScrollStitchCore
import Foundation

public enum CaptureSampleKind: Sendable { case video, appAudio, microphoneAudio }
public struct OwnedVideoFrame: Sendable {
    public let png: Data
    public let size: PixelSize
    public let pts: Double
    public let orientation: Int
    public init(png: Data, size: PixelSize, pts: Double, orientation: Int = 1) {
        self.png = png; self.size = size; self.pts = pts; self.orientation = orientation
    }
}
public enum CaptureResult: Equatable, Sendable {
    case ignoredAudio, accepted(UUID), duplicate, sampledOut, stopped(CaptureEndReason)
}

public struct CaptureLimits: Sendable {
    public let seconds: Double
    public let frames: Int
    public let bytes: Int
    public let sampleInterval: Double
    public init(seconds: Double = 120, frames: Int = 200, bytes: Int = 256 * 1024 * 1024, sampleInterval: Double = 0.5) throws {
        guard seconds.isFinite, seconds > 0, seconds <= 120, frames > 0, frames <= 200,
              bytes > 0, sampleInterval.isFinite, sampleInterval >= 0 else { throw ScrollStitchError.budgetExceeded }
        self.seconds = seconds; self.frames = frames; self.bytes = bytes; self.sampleInterval = sampleInterval
    }
    public static let standard = try! CaptureLimits()
}

/// Owned by the serialized video consumer. No CMSampleBuffer is retained here.
public final class CaptureSession {
    public let taskID: UUID
    private let store: TaskStore
    private var owner: FileLease?
    private let limits: CaptureLimits
    private let startedUptime: Double
    private var lastSampleUptime: Double?
    private var geometry: PixelSize?
    private var orientation: Int?
    private var lastDigest: String?
    public private(set) var acceptedFrames = 0
    public private(set) var storedBytes = 0
    /// Bytes committed or reserved by the video-only recovery archive.
    public var externalStoredBytes = 0
    public var prepareToFinish: (() -> Void)?
    public init(store: TaskStore, now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime,
                limits: CaptureLimits = .standard) throws {
        guard uptime.isFinite, uptime >= 0 else { throw ScrollStitchError.corruptData }
        self.limits = limits; self.startedUptime = uptime
        self.store = store
        let (task, lease) = try store.beginCapture(now: now)
        taskID = task.taskID; owner = lease
    }
    /// Called by the capture timer as well as frame callbacks, so a no-frame session also ends.
    public func tick(uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> CaptureEndReason? {
        guard owner != nil else { return nil }
        guard uptime.isFinite, uptime >= startedUptime else { throw ScrollStitchError.corruptData }
        if uptime - startedUptime >= limits.seconds { try finish(.timeBudget); return .timeBudget }
        return nil
    }
    public func process(_ kind: CaptureSampleKind, uptime: Double = ProcessInfo.processInfo.systemUptime,
                        makeFrame: () throws -> OwnedVideoFrame) throws -> CaptureResult {
        guard kind == .video else { return .ignoredAudio }
        guard owner != nil else { throw ScrollStitchError.noTask }
        if let reason = try tick(uptime: uptime) { return .stopped(reason) }
        if let lastSampleUptime, uptime - lastSampleUptime < limits.sampleInterval { return .sampledOut }
        lastSampleUptime = uptime
        do {
            let frame = try makeFrame()
            guard frame.size.height >= frame.size.width,
                  geometry == nil || geometry == frame.size,
                  orientation == nil || orientation == frame.orientation else {
                try finish(.sizeChanged); return .stopped(.sizeChanged)
            }
            let digest = TaskStore.digest(data: frame.png)
            if digest == lastDigest { return .duplicate }
            guard externalStoredBytes>=0, externalStoredBytes<=limits.bytes-storedBytes,
                  frame.png.count <= limits.bytes - storedBytes - externalStoredBytes else {
                try finish(.storageBudget); return .stopped(.storageBudget)
            }
            guard let owner else { throw ScrollStitchError.noTask }
            let record = try store.appendFrame(taskID: taskID, owner: owner, png: frame.png,
                                                size: frame.size, pts: frame.pts, orientation: frame.orientation)
            geometry = frame.size; orientation = frame.orientation; lastDigest = digest
            storedBytes += frame.png.count; acceptedFrames += 1
            if acceptedFrames == limits.frames { try finish(.frameBudget); return .stopped(.frameBudget) }
            return .accepted(record.id)
        } catch {
            try? finish(.writeFailure)
            throw error
        }
    }
    /// ReplayKit's finished callback provides no verifiable cause or user intent.
    /// Preserve the committed prefix without claiming completion or refreshing user activity.
    public func finishFromSystem() throws {
        try finish(.unknown)
    }
    public func finish(_ reason: CaptureEndReason) throws {
        guard let owner else { return }
        prepareToFinish?()
        defer { self.owner = nil }
        try store.finishCapture(taskID: taskID, owner: owner, reason: reason)
    }
}
