import Foundation

public enum ScrollAxis: String, Codable, CaseIterable, Sendable { case vertical, horizontal }
public enum ScrollPhase: String, Codable, Sendable {
    case choosing, starting, recording, pausing, paused, sealing, processing, saving, saved
    case permissionRequired, interrupted, failed, saveUncertain
    public var capturing: Bool { [.choosing, .starting, .recording, .pausing, .paused, .sealing].contains(self) }
    public var unfinished: Bool { capturing || self == .processing || self == .saving }
}
public enum ScrollEvent: Sendable {
    case selected, recordingStarted, pagePaused(Int), pageResumed(Int), finish, inputSealed
    case reconstructed, photosSaved(Int), permissionDenied, uncertainSave, failed(String), interrupted
}
public struct ScrollRecording: Codable, Equatable, Sendable {
    public let path: AssetPath
    public let page: Int
    public let sha256: String
    public let bytes: Int
    public init(path: AssetPath, page: Int, sha256: String, bytes: Int) {
        self.path=path; self.page=page; self.sha256=sha256; self.bytes=bytes
    }
}

/// A durable user request. Views never own this state or start automatic work.
public struct ScrollSession: Codable, Equatable, Sendable, Identifiable {
    public var version = 1
    public let id: UUID
    public let taskID: UUID
    public let axis: ScrollAxis
    public let createdAt: Date
    public private(set) var phase: ScrollPhase = .choosing
    public private(set) var page = 0
    // Decode/re-encode existing works without changing their source inventory.
    // New capture writes frames to TaskStore and never appends video records.
    public private(set) var recordings: [ScrollRecording] = []
    public private(set) var savedPages = 0
    public private(set) var message: String?
    public init(id: UUID = UUID(), taskID: UUID, axis: ScrollAxis, now: Date = Date()) {
        self.id=id; self.taskID=taskID; self.axis=axis; self.createdAt=now
    }
    public mutating func apply(_ event: ScrollEvent) throws {
        switch (phase,event) {
        case (.choosing,.selected): phase = .starting
        case (.starting,.recordingStarted): phase = .recording
        case (.recording,.pagePaused(let current)),(.paused,.pagePaused(let current)):
            guard current == page else { throw ScrollStitchError.staleOperation }
            phase = .paused
        case (.paused,.pageResumed(let next)):
            guard next == page || next == page + 1 else { throw ScrollStitchError.staleOperation }
            page = next; phase = .recording
        case (.recording,.pageResumed(let current)):
            guard current == page else { throw ScrollStitchError.staleOperation }
        case (.recording,.finish),(.paused,.finish),(.starting,.finish): phase = .sealing
        case (.sealing,.inputSealed): phase = .processing
        case (.processing,.reconstructed): phase = .saving
        case (.saving,.photosSaved(let count)):
            guard count>0 else { throw ScrollStitchError.corruptData }
            savedPages=count; phase = .saved; message=nil
        case (.saving,.permissionDenied): phase = .permissionRequired
        case (.saving,.uncertainSave): phase = .saveUncertain
        case (_,.failed(let reason)): phase = .failed; message=String(reason.prefix(240))
        case (_,.interrupted): phase = .interrupted
        // Duplicate delivery cannot toggle a paused session or increment its page.
        case (.starting,.selected),(.recording,.recordingStarted),
             (.sealing,.finish),(.processing,.inputSealed),
             (.saving,.reconstructed): return
        default: throw ScrollStitchError.staleOperation
        }
    }
    /// Recovery repeats computation, but never guesses whether a Photos write succeeded.
    public mutating func recover(hasResult: Bool, hasUncertainPhotoWrite: Bool) {
        if phase.capturing { phase = .interrupted }
        else if phase == .processing || phase == .saving {
            phase = hasUncertainPhotoWrite ? .saveUncertain : (hasResult ? .saving : .processing)
        }
    }
    public mutating func retryKnownFailure(hasResult: Bool) throws {
        guard [.permissionRequired,.failed,.interrupted].contains(phase) else {
            throw ScrollStitchError.staleOperation
        }
        phase = hasResult ? .saving : .processing; message=nil
    }
    public func validate() throws {
        guard version == 1 else { throw ScrollStitchError.unsupportedSchema }
        guard page>=0,page<512,savedPages>=0,recordings.count<=512,
              Set(recordings.map(\.path)).count == recordings.count else { throw ScrollStitchError.corruptData }
        for record in recordings {
            guard record.page>=0,record.page<=page,record.bytes>0,
                  record.path.value.hasPrefix("recording/"),record.path.value.hasSuffix(".mp4"),
                  record.sha256.count==64,record.sha256.allSatisfy(\.isHexDigit) else {
                throw ScrollStitchError.corruptData
            }
        }
    }
}

/// Each work owns a TaskStore. A new session never clears a previous work.
/// The main app is the sole command executor; the extension only reads snapshots.
public final class ScrollLibrary: @unchecked Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root=root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try TaskStore.protect(root)
    }
    public func store(for id: UUID) throws -> TaskStore {
        try TaskStore(root:root.appendingPathComponent(id.uuidString))
    }
    public func sessions() throws -> [ScrollSession] {
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey])
        var values=[ScrollSession]()
        for file in files where UUID(uuidString:file.lastPathComponent) != nil {
            guard (try file.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ScrollStitchError.invalidPath
            }
            let path=file.appendingPathComponent("scroll-session.json")
            guard FileManager.default.fileExists(atPath:path.path) else { continue }
            let value=try JSONDecoder().decode(ScrollSession.self,from:Data(contentsOf:path))
            try value.validate()
            guard value.id.uuidString == file.lastPathComponent else { throw ScrollStitchError.corruptData }
            values.append(value)
        }
        return values.sorted {$0.createdAt>$1.createdAt}
    }
    public func save(_ session: ScrollSession) throws {
        try session.validate()
        let directory=root.appendingPathComponent(session.id.uuidString)
        guard FileManager.default.fileExists(atPath:directory.path) else { throw ScrollStitchError.wrongTask }
        let file=directory.appendingPathComponent("scroll-session.json")
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(session).write(to:file,options:.atomic)
        try TaskStore.protect(file)
        let handle=try FileHandle(forWritingTo:file)
        defer {try? handle.close()}
        try handle.synchronize()
    }
    public func begin(axis: ScrollAxis) throws -> (ScrollSession,TaskStore,FileLease) {
        guard !(try sessions()).contains(where:{$0.phase.unfinished}) else {
            throw ScrollStitchError.captureActive
        }
        let id=UUID(),store=try store(for:id)
        let (manifest,lease)=try store.beginCapture()
        let session=ScrollSession(id:id,taskID:manifest.taskID,axis:axis)
        try save(session)
        return (session,store,lease)
    }
}
