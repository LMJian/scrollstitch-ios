import Foundation

public enum ResultExportError: Error, Equatable, Sendable {
    case alreadySaved, unconfirmedWrite, invalidResult
}

/// Describes a complete encoded image, never the view's thumbnail.
public struct ResultManifest: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion = 1
    public let taskID: UUID
    public let revision: UInt64
    public let selectionFingerprint: String
    public let path: AssetPath
    public let format: String
    public let size: PixelSize
    public let sizeBytes: Int
    public let sha256: String
    public let createdAt: Date
    public var completenessNote:String? = nil
    public var id: String {
        TaskStore.digest(data:Data(("\(taskID)|\(revision)|\(selectionFingerprint)|\(format)|\(sha256)"+(completenessNote.map{"|"+$0} ?? "")).utf8))
    }
    public init(taskID: UUID, revision: UInt64, selectionFingerprint: String, path: AssetPath,
                format: String, size: PixelSize, sizeBytes: Int, sha256: String, createdAt: Date = Date()) {
        self.taskID=taskID; self.revision=revision; self.selectionFingerprint=selectionFingerprint
        self.path=path; self.format=format; self.size=size; self.sizeBytes=sizeBytes
        self.sha256=sha256
        self.createdAt=Date(timeIntervalSince1970:(createdAt.timeIntervalSince1970*1000).rounded()/1000)
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ScrollStitchError.unsupportedSchema }
        guard completenessNote.map({!$0.isEmpty && $0.count<=200}) ?? true else { throw ResultExportError.invalidResult }
        guard ["png","jpeg"].contains(format), path.value.hasPrefix("exports/"),
              path.value.split(separator:"/").count == 2, path.value.hasSuffix("."+format),
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              selectionFingerprint.count == 64, selectionFingerprint.allSatisfy(\.isHexDigit),
              sizeBytes > 0, size.pixels <= 24_000_000,
              min(size.width,size.height)<=4096,max(size.width,size.height)<=32000 else {
            throw ResultExportError.invalidResult
        }
    }
}

public enum PhotoSavePhase: String, Codable, Sendable { case writing, saved, failed }
public struct PhotoSaveRecord: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let resultID: String
    public var phase: PhotoSavePhase
    public var updatedAt: Date
    public init(operationID: UUID = UUID(), resultID: String, phase: PhotoSavePhase, now: Date = Date()) {
        self.operationID=operationID; self.resultID=resultID; self.phase=phase; self.updatedAt=now
    }
}
struct PhotoSaveLedger: Codable { var schemaVersion=1; var records: [String:PhotoSaveRecord]=[:] }

/// One owner spans permission UI, the platform operation and its final callback.
public final class ResultAccess: @unchecked Sendable {
    public let result: ResultManifest
    public let url: URL
    let lease: FileLease
    init(result: ResultManifest, url: URL, lease: FileLease) {
        self.result=result; self.url=url; self.lease=lease
    }
}

public enum PhotoAuthorization: Sendable { case notDetermined, authorized, denied, restricted }
public protocol PhotoLibraryWriting: Sendable {
    func authorization() async -> PhotoAuthorization
    func requestAddOnly() async -> PhotoAuthorization
    func write(fileURL: URL) async throws
}
public enum PhotoExportState: Equatable, Sendable {
    case ready, authorizing, writing, saved, denied, restricted, failed, unknown
    public var isBusy: Bool { self == .authorizing || self == .writing }
}

/// The pure coordinator is exercised with a controllable writer; the iOS adapter
/// alone owns PhotoKit. No timeout converts an uncertain write into a retry.
@MainActor public final class PhotoExportController {
    public private(set) var state: PhotoExportState = .ready
    private var writingInFlight=false,batchInFlight=false
    public var inFlight:Bool { writingInFlight || batchInFlight }
    public var onChange: (@MainActor (PhotoExportState) -> Void)?
    private let writer: any PhotoLibraryWriting
    public init(writer: any PhotoLibraryWriting) { self.writer=writer }
    private func publish(_ next: PhotoExportState) { state=next; onChange?(next) }
    public func restore(_ record: PhotoSaveRecord?, unreadable: Bool = false) {
        guard !inFlight else { return }
        if unreadable { publish(.unknown); return }
        switch record?.phase {
        case .saved: publish(.saved)
        case .writing: publish(.unknown)
        case .failed: publish(.failed)
        case nil: publish(.ready)
        }
    }
    public func save(store: TaskStore, result: ResultManifest, confirmedRepeat: Bool = false) async {
        guard !inFlight else { return }
        await saveOne(store:store,result:result,confirmedRepeat:confirmedRepeat,requestPermission:true)
    }
    /// Commit and record one page at a time. Known successes are skipped; an
    /// uncertain page stops the batch without retrying that write or later pages.
    @discardableResult public func saveAll(store:TaskStore,results:[ResultManifest],requestPermission:Bool = true,
        cancelled:@MainActor ()->Bool = {false},progress:@MainActor (Int,Int)->Void = {_,_ in}) async -> Int {
        guard !inFlight else { return 0 }
        batchInFlight=true;defer { batchInFlight=false }
        var saved=0
        for result in results {
            if cancelled() { break }
            progress(saved,results.count)
            await saveOne(store:store,result:result,confirmedRepeat:false,requestPermission:requestPermission)
            guard state == .saved else { break }
            saved+=1;progress(saved,results.count)
        }
        return saved
    }
    private func saveOne(store:TaskStore,result:ResultManifest,confirmedRepeat:Bool,requestPermission:Bool) async {
        writingInFlight=true
        defer { writingInFlight=false }
        publish(.authorizing)
        do {
            let access = try await Task.detached {
                try store.recordInteraction(taskID:result.taskID)
                return try store.openResult(taskID:result.taskID, resultID:result.id)
            }.value
            let prior = try await Task.detached { try store.photoSaveRecord(access) }.value
            if !confirmedRepeat, let prior, prior.phase != .failed {
                publish(prior.phase == .saved ? .saved : .unknown); return
            }
            var permission = await writer.authorization()
            if permission == .notDetermined,requestPermission { permission = await writer.requestAddOnly() }
            guard permission == .authorized else {
                publish(permission == .restricted ? .restricted : .denied); return
            }
            let intent = try await Task.detached { try store.beginPhotoSave(access,confirmedRepeat:confirmedRepeat) }.value
            publish(.writing)
            do { try await writer.write(fileURL:access.url) }
            catch {
                do { try await Task.detached { try store.finishPhotoSave(access,operationID:intent.operationID,success:false) }.value; publish(.failed) }
                catch { publish(.unknown) }
                return
            }
            do {
                try await Task.detached { try store.finishPhotoSave(access,operationID:intent.operationID,success:true) }.value
                publish(.saved)
            } catch { publish(.unknown) }
            withExtendedLifetime(access) {}
        } catch ResultExportError.alreadySaved { publish(.saved) }
          catch ResultExportError.unconfirmedWrite { publish(.unknown) }
          catch { publish(.failed) }
    }
}
