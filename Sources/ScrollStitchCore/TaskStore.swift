import Foundation
import CryptoKit
import ImageIO
import Darwin

public final class FileLease: @unchecked Sendable {
    fileprivate let path: String
    private let descriptor: Int32
    fileprivate init(url: URL, nonblocking: Bool) throws {
        path = url.path
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScrollStitchError.storageFailure }
        if flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            close(descriptor); throw ScrollStitchError.resourceBusy
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public enum StoreFaultPoint: Sendable, Equatable {
    case afterAssetWrite, afterAssetRename, beforeSnapshotReplace, afterSnapshotReplace
    case beforeResultPublish, beforePhotoSaveIntent, beforePhotoSaveCompletion
    case beforeEditReplace, afterEditReplace
}

/// Every operation opens its own flock descriptor: serialization spans threads and processes.
public final class TaskStore: @unchecked Sendable {
    public let root: URL
    private let fault: (@Sendable (StoreFaultPoint) throws -> Void)?
    /// Keep app-owned data inside Library so Apple's device file service can export it.
    /// Move the pre-M0 location only when no capture, render or share owns its files.
    public static func inAppGroup(_ container: URL) throws -> TaskStore {
        let library = try AssetPath("Library").resolved(in: container)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let locationLock = try FileLease(url: AssetPath("ScrollStitch-location.lock").resolved(in: library), nonblocking: false)
        return try withExtendedLifetime(locationLock) {
            let destination = try AssetPath("ScrollStitch").resolved(in: library)
            let legacy = try AssetPath("ScrollStitch").resolved(in: container)
            if FileManager.default.fileExists(atPath: legacy.path) {
                // Never choose between two existing stores or overwrite either one.
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScrollStitchError.existingTask }
                let capture = try FileLease(url: AssetPath("capture-owner.lock").resolved(in: legacy), nonblocking: true)
                let share = try FileLease(url: AssetPath("share-owner.lock").resolved(in: legacy), nonblocking: true)
                let transaction = try FileLease(url: AssetPath("coordination.lock").resolved(in: legacy), nonblocking: false)
                try withExtendedLifetime((capture, share, transaction)) {
                    // Both paths belong to the same App Group volume. moveItem refuses
                    // an existing destination and preserves all snapshots and asset bytes.
                    try FileManager.default.moveItem(at: legacy, to: destination)
                }
            }
            return try TaskStore(root: destination)
        }
    }
    public init(root: URL, fault: (@Sendable (StoreFaultPoint) throws -> Void)? = nil) throws {
        self.root = root.standardizedFileURL; self.fault = fault
        guard self.root.resolvingSymlinksInPath().path == self.root.path else { throw ScrollStitchError.invalidPath }
        try Self.makeDirectory(self.root)
        try Self.makeDirectory(try file("tasks"))
    }
    private func file(_ relative: String) throws -> URL { try AssetPath(relative).resolved(in: root) }
    public func taskDirectory(_ id: UUID) throws -> URL { try file("tasks/" + id.uuidString) }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        let lock = try FileLease(url: file("coordination.lock"), nonblocking: false)
        return try withExtendedLifetime(lock, operation)
    }
    private func readCurrent() throws -> TaskManifest? {
        let url = try file("current.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value: TaskManifest = try Self.read(url)
        try value.validate(); return value
    }
    private func requireCurrent(_ id: UUID) throws -> TaskManifest {
        guard let value = try readCurrent() else { throw ScrollStitchError.noTask }
        guard value.taskID == id, !value.deleting else { throw ScrollStitchError.wrongTask }
        return value
    }
    private func create(_ kind: TaskKind, now: Date) throws -> TaskManifest {
        guard try readCurrent() == nil else { throw ScrollStitchError.existingTask }
        let manifest = TaskManifest(kind: kind, now: now)
        let directory = try taskDirectory(manifest.taskID)
        try Self.makeDirectory(directory)
        for child in ["assets", "temporary", "exports"] { try Self.makeDirectory(directory.appendingPathComponent(child)) }
        if kind == .capture {
            try Self.write(CaptureSnapshot(taskID: manifest.taskID, startedAt: now), to: directory.appendingPathComponent("capture.json"))
        } else {
            try Self.write(EditSnapshot(taskID: manifest.taskID), to: directory.appendingPathComponent("edit.json"))
        }
        try Self.write(manifest, to: file("current.json"))
        return manifest
    }
    public func createCollage(now: Date = Date()) throws -> TaskManifest {
        try transaction {
            let owner = try FileLease(url: file("capture-owner.lock"), nonblocking: true)
            return try withExtendedLifetime(owner) { try create(.collage, now: now) }
        }
    }
    public func beginCapture(now: Date = Date()) throws -> (TaskManifest, FileLease) {
        guard BuildMode.captureCreationEnabled else { throw ScrollStitchError.invalidSelection }
        let owner = try FileLease(url: file("capture-owner.lock"), nonblocking: true)
        return try transaction { (try create(.capture, now: now), owner) }
    }
    public func current() throws -> TaskManifest? { try transaction { try readCurrent() } }
    /// A user-requested retry may retire an empty, stopped startup attempt. Keep
    /// every byte in its original task directory; never discard a captured frame,
    /// a recoverable video chunk, an edit, or an unrecognized file.
    public func retireEmptyCaptureForRetry() throws {
        try transaction {
            guard let manifest = try readCurrent() else { return }
            let owners = [try FileLease(url: file("capture-owner.lock"), nonblocking: true),
                          try FileLease(url: file("share-owner.lock"), nonblocking: true)]
            try withExtendedLifetime(owners) {
                guard manifest.kind == .capture, !manifest.deleting, !manifest.pendingCleanup else {
                    throw ScrollStitchError.existingTask
                }
                let capture = try captureSnapshotUnlocked(taskID: manifest.taskID, verifyFiles: false)
                guard capture.frames.isEmpty, capture.phase == .ended || capture.phase == .interrupted else {
                    throw ScrollStitchError.existingTask
                }
                let directory = try taskDirectory(manifest.taskID)
                let allowed = Set(["capture.json", "recording/index.json", "recording/timeline-v2.json", "analysis-v2/session.json", "result-set-v2.json"])
                var emptyIdentity=try Data(contentsOf:directory.appendingPathComponent("capture.json"))
                let archiveIndex=try AssetPath("recording/index.json").resolved(in:directory)
                if FileManager.default.fileExists(atPath:archiveIndex.path) {emptyIdentity.append(try Data(contentsOf:archiveIndex))}
                let identity=Self.digest(data:emptyIdentity)
                guard let entries = FileManager.default.enumerator(atPath: directory.path) else {
                    throw ScrollStitchError.storageFailure
                }
                for case let relative as String in entries {
                    let entry = try AssetPath(relative).resolved(in: directory)
                    let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw ScrollStitchError.invalidPath }
                    if values.isRegularFile == true {
                        guard allowed.contains(relative) else { throw ScrollStitchError.existingTask }
                        if relative == "analysis-v2/session.json" {
                            let session=try JSONDecoder().decode(CaptureAnalysisSession.self,from:Data(contentsOf:entry))
                            try session.validate()
                            guard session.revision==capture.sequence,session.sourceIdentity==identity else {throw ScrollStitchError.existingTask}
                        }
                        if relative == "result-set-v2.json" {
                            let result:CaptureResultSet=try Self.read(entry)
                            try result.validate()
                            guard result.taskID==manifest.taskID,result.revision==capture.sequence,result.sourceIdentity==identity,
                                  result.status == .noUsableContent,result.pages.isEmpty else {throw ScrollStitchError.existingTask}
                        }
                        if relative == "recording/timeline-v2.json" {
                            let timeline=try JSONDecoder().decode(CaptureTimeline.self,from:Data(contentsOf:entry))
                            try timeline.validate()
                            guard timeline.finished,timeline.acceptedSourceSamples.isEmpty,timeline.segmentHashes.isEmpty else { throw ScrollStitchError.existingTask }
                        }
                        if relative == "recording/index.json" {
                            let index = try JSONDecoder().decode(CaptureVideoIndex.self, from: Data(contentsOf: entry))
                            guard index.version == 1, index.finished, index.segments.isEmpty else { throw ScrollStitchError.existingTask }
                        }
                    }
                }
                // Atomic rename releases the current slot without deleting evidence.
                try FileManager.default.moveItem(at: file("current.json"),
                    to: directory.appendingPathComponent("retired-startup.json"))
            }
        }
    }
    /// Call only for a confirmed user action; polling/readback must not renew the TTL.
    public func recordInteraction(taskID: UUID, now: Date = Date()) throws {
        try transaction {
            var manifest = try requireCurrent(taskID)
            guard !manifest.pendingCleanup, !manifest.deleting else { throw ScrollStitchError.staleOperation }
            manifest.lastInteractionAt = now
            try Self.write(manifest, to:file("current.json"))
        }
    }
    public func captureSnapshot(taskID: UUID, verifyFiles: Bool = true) throws -> CaptureSnapshot {
        try transaction { try captureSnapshotUnlocked(taskID: taskID, verifyFiles: verifyFiles) }
    }
    private func captureSnapshotUnlocked(taskID: UUID, verifyFiles: Bool) throws -> CaptureSnapshot {
        let manifest = try requireCurrent(taskID)
        guard manifest.kind == .capture else { throw ScrollStitchError.wrongTask }
        let directory = try taskDirectory(taskID)
        let value: CaptureSnapshot = try Self.read(directory.appendingPathComponent("capture.json"))
        try value.validate()
        guard value.taskID == taskID else { throw ScrollStitchError.corruptData }
        if verifyFiles { for f in value.frames { try verify(f.asset, taskID: taskID) } }
        return value
    }
    public func verify(_ asset: SourceAsset, taskID: UUID) throws {
        try asset.validate()
        let url = try asset.path.resolved(in: taskDirectory(taskID))
        guard try Self.digest(url: url) == asset.sha256 else { throw ScrollStitchError.corruptData }
    }
    public func assetURL(_ asset: SourceAsset, taskID: UUID) throws -> URL {
        try verify(asset, taskID: taskID)
        return try asset.path.resolved(in: taskDirectory(taskID))
    }
    public func appendFrame(taskID: UUID, owner: FileLease, png: Data, size: PixelSize,
                            pts: Double, orientation: Int = 1, now: Date = Date()) throws -> FrameRecord {
        try appendEncodedFrame(taskID: taskID, owner: owner, data: png, size: size, pts: pts,
                               orientation: orientation, now: now, fileExtension: "png")
    }
    public func appendCapturedFrame(taskID: UUID, owner: FileLease, jpeg: Data, size: PixelSize,
                                    pts: Double, now: Date = Date()) throws -> FrameRecord {
        try appendEncodedFrame(taskID: taskID, owner: owner, data: jpeg, size: size, pts: pts,
                               orientation: 1, now: now, fileExtension: "jpg")
    }
    private func appendEncodedFrame(taskID: UUID, owner: FileLease, data: Data, size: PixelSize,
                                     pts: Double, orientation: Int, now: Date, fileExtension: String) throws -> FrameRecord {
        try transaction {
            guard owner.path == (try file("capture-owner.lock")).path else { throw ScrollStitchError.captureActive }
            var snapshot = try captureSnapshotUnlocked(taskID: taskID, verifyFiles: false)
            guard snapshot.phase == .capturing, snapshot.frames.count < 4000 else { throw ScrollStitchError.budgetExceeded }
            guard pts.isFinite, pts >= (snapshot.frames.last?.monotonicPTS ?? 0), (1...8).contains(orientation) else {
                throw ScrollStitchError.corruptData
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == size.width, image.height == size.height else { throw ScrollStitchError.corruptData }
            let id = UUID(), directory = try taskDirectory(taskID)
            let temporary = directory.appendingPathComponent("temporary/" + id.uuidString + "." + fileExtension)
            let relative = try AssetPath("assets/" + id.uuidString + "." + fileExtension)
            let destination = try relative.resolved(in: directory)
            try Self.atomicData(data, to: temporary)
            try fault?(.afterAssetWrite)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try fault?(.afterAssetRename)
            let asset = SourceAsset(id: id, path: relative, size: size, sha256: Self.digest(data: data))
            let frame = FrameRecord(asset: asset, ordinal: snapshot.frames.count, monotonicPTS: pts, orientation: orientation)
            snapshot.frames.append(frame); snapshot.sequence += 1; snapshot.lastFrameAt = now
            try fault?(.beforeSnapshotReplace)
            try Self.write(snapshot, to: directory.appendingPathComponent("capture.json"))
            try fault?(.afterSnapshotReplace)
            return frame
        }
    }
    public func finishCapture(taskID: UUID, owner: FileLease, reason: CaptureEndReason, now: Date = Date()) throws {
        try transaction {
            guard owner.path == (try file("capture-owner.lock")).path else { throw ScrollStitchError.captureActive }
            var value = try captureSnapshotUnlocked(taskID: taskID, verifyFiles: false)
            guard value.phase == .capturing else { return }
            value.phase = reason == .userStopped ? .ended : .interrupted
            value.endReason = reason; value.sequence += 1
            try Self.write(value, to: taskDirectory(taskID).appendingPathComponent("capture.json"))
            if reason == .userStopped {
                var manifest = try requireCurrent(taskID)
                manifest.lastInteractionAt = now
                try Self.write(manifest, to: file("current.json"))
            }
        }
    }
    public func reconcileCapture(taskID: UUID) throws -> CaptureSnapshot {
        try transaction {
            var value = try captureSnapshotUnlocked(taskID: taskID, verifyFiles: true)
            let owner: FileLease
            do { owner = try FileLease(url: file("capture-owner.lock"), nonblocking: true) }
            catch ScrollStitchError.resourceBusy {
                // Even an end marker cannot enable processing until the writer releases ownership.
                value.phase = .reconciling; value.endReason = nil; return value
            }
            return try withExtendedLifetime(owner) {
                if value.phase == .capturing || value.phase == .reconciling {
                    value.phase = .interrupted; value.endReason = .ownerLost; value.sequence += 1
                    try Self.write(value, to: taskDirectory(taskID).appendingPathComponent("capture.json"))
                }
                let reader: FileLease
                do { reader = try FileLease(url: file("share-owner.lock"), nonblocking: true) }
                catch ScrollStitchError.resourceBusy { return value }
                // Render/share uses the same lease; its temporary files are not crash debris.
                return try withExtendedLifetime(reader) {
                let referenced = Set(value.frames.map { $0.asset.path.value })
                let directory = try taskDirectory(taskID)
                for folder in ["assets", "temporary"] {
                    let url = try AssetPath(folder).resolved(in: directory)
                    for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        let relative = try AssetPath(folder + "/" + item.lastPathComponent)
                        let safe = try relative.resolved(in: directory)
                        if !referenced.contains(relative.value) { try FileManager.default.removeItem(at: safe) }
                    }
                }
                return value
                }
            }
        }
    }
    public func editSnapshot(taskID: UUID) throws -> EditSnapshot {
        let value = try transaction { try readEdit(taskID) }
        // Hash large files outside the cross-process metadata lock.
        for asset in value.assets { try verify(asset,taskID:taskID) }
        return value
    }
    private func readEdit(_ taskID: UUID) throws -> EditSnapshot {
        _ = try requireCurrent(taskID)
        let value: EditSnapshot = try Self.read(taskDirectory(taskID).appendingPathComponent("edit.json"))
        try value.validate()
        guard value.taskID == taskID else { throw ScrollStitchError.corruptData }
        return value
    }
    /// Legacy callers also get a single undo. Batch import uses its own token-checked commits.
    public func commitEdit(_ edit: EditSnapshot, expectedRevision: UInt64, now: Date = Date()) throws -> EditSnapshot {
        try edit.validate()
        for asset in edit.assets { try verify(asset,taskID:edit.taskID) }
        return try transaction {
            let old = try readEdit(edit.taskID)
            guard old.activeImport == nil else { throw ScrollStitchError.resourceBusy }
            return try persistEdit(edit, old:old, expectedRevision:expectedRevision, label:"编辑", now:now)
        }
    }
    public func applyEdit(taskID: UUID, expectedRevision: UInt64, command: EditCommand, now: Date = Date()) throws -> EditSnapshot {
        let owner=try acquireShareLease(taskID:taskID)
        return try withExtendedLifetime(owner) {
            let old=try editSnapshot(taskID:taskID), (next,label)=try old.applying(command)
            return try transaction {
                try persistEdit(next,old:old,expectedRevision:expectedRevision,label:label,now:now)
            }
        }
    }
    public func undoEdit(taskID: UUID, expectedRevision: UInt64, now: Date = Date()) throws -> EditSnapshot {
        let owner=try acquireShareLease(taskID:taskID)
        return try withExtendedLifetime(owner) {
            let old=try editSnapshot(taskID:taskID)
            guard old.activeImport == nil else { throw ScrollStitchError.resourceBusy }
            guard let undo=old.undo else { throw ScrollStitchError.invalidSelection }
            for asset in undo.payload.assets { try verify(asset,taskID:taskID) }
            var next=old; next.payload=undo.payload; next.undo=nil
            return try transaction {
                try persistEdit(next,old:old,expectedRevision:expectedRevision,label:nil,now:now,force:true)
            }
        }
    }
    private func persistEdit(_ edit: EditSnapshot, old: EditSnapshot, expectedRevision: UInt64,
                             label: String?, now: Date, force: Bool = false) throws -> EditSnapshot {
        var manifest=try requireCurrent(edit.taskID)
        guard manifest.kind == .collage, !manifest.pendingCleanup else { throw ScrollStitchError.staleOperation }
        guard old.revision==expectedRevision, try readEdit(edit.taskID).revision==expectedRevision, expectedRevision<UInt64.max else { throw ScrollStitchError.revisionConflict }
        guard force || edit.payload != old.payload else { return old }
        var next=edit; next.payload=edit.payload; next.schemaVersion=2; next.revision=expectedRevision+1
        next.committedAt=Date(timeIntervalSince1970:(now.timeIntervalSince1970*1000).rounded()/1000)
        if let label { next.undo=EditUndo(payload:old.payload,label:label) }
        try next.validate()
        let directory=try taskDirectory(next.taskID), url=directory.appendingPathComponent("edit.json")
        let backup=directory.appendingPathComponent("edit-v1-backup.json")
        if old.schemaVersion==1, !FileManager.default.fileExists(atPath:backup.path) {
            try Self.atomicData(Data(contentsOf:url),to:backup)
        }
        try fault?(.beforeEditReplace)
        try Self.write(next,to:url)
        // The edit is committed. A manifest/notification failure must not cause a retry
        // of the user's edit. TTL reads the committed timestamp until repair succeeds.
        do {
            try fault?(.afterEditReplace)
            manifest.lastInteractionAt=max(manifest.lastInteractionAt,next.committedAt!)
            try Self.write(manifest,to:file("current.json"))
        } catch {
            let committed=try readEdit(next.taskID)
            guard committed==next else { throw ScrollStitchError.storageFailure }
        }
        return next
    }
    /// Call on foreground recovery, only after the live importer releases its lease.
    public func reconcileEdit(taskID: UUID) throws -> EditSnapshot {
        let owner: FileLease
        do { owner=try acquireShareLease(taskID:taskID) }
        catch ScrollStitchError.resourceBusy { return try editSnapshot(taskID:taskID) }
        return try withExtendedLifetime(owner) {
            let value: EditSnapshot = try transaction {
                var value=try readEdit(taskID)
                if value.activeImport != nil || value.imports.contains(where:{$0.issue == .loading}) {
                    let old=value
                    for i in value.imports.indices where value.imports[i].issue == .loading { value.imports[i].issue = .cancelled }
                    value.activeImport=nil
                    value=try persistEdit(value,old:old,expectedRevision:old.revision,label:nil,
                                          now:old.committedAt ?? requireCurrent(taskID).lastInteractionAt,force:true)
                }
                var manifest=try requireCurrent(taskID)
                if let committedAt=value.committedAt,committedAt>manifest.lastInteractionAt {
                    manifest.lastInteractionAt=committedAt
                    try? Self.write(manifest,to:file("current.json"))
                }
                return value
            }
            for asset in value.assets { try verify(asset,taskID:taskID) }
            return try transaction {
                guard try readEdit(taskID).revision==value.revision else { throw ScrollStitchError.revisionConflict }
                let referenced=Set((value.assets+(value.undo?.payload.assets ?? [])).map { $0.path.value })
                let directory=try taskDirectory(taskID)
                for folder in ["assets","temporary"] {
                    for item in try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent(folder),includingPropertiesForKeys:nil) {
                        let path=try AssetPath(folder+"/"+item.lastPathComponent)
                        if !referenced.contains(path.value) { try FileManager.default.removeItem(at:path.resolved(in:directory)) }
                    }
                }
                return value
            }
        }
    }
    public func beginImport(taskID: UUID? = nil, expectedRevision: UInt64? = nil, replacing: UUID? = nil,
                            selections: [ImportSelection], now: Date = Date()) throws -> ImportBatchAccess? {
        try transaction {
            guard !selections.isEmpty, selections.count<=20, Set(selections.map(\.id)).count==selections.count else {
                throw ScrollStitchError.invalidSelection
            }
            let capture=try FileLease(url:file("capture-owner.lock"),nonblocking:true)
            let owner=try FileLease(url:file("share-owner.lock"),nonblocking:true)
            return try withExtendedLifetime(capture) {
                var old: EditSnapshot?
                if let taskID {
                    let value=try readEdit(taskID)
                    guard value.revision==expectedRevision else { throw ScrollStitchError.revisionConflict }
                    guard value.activeImport == nil else { throw ScrollStitchError.resourceBusy }
                    old=value
                } else { guard try readCurrent() == nil, replacing == nil else { throw ScrollStitchError.existingTask } }
                let previous=old?.orderedImports ?? []
                if let replacing {
                    guard selections.count==1, previous.contains(where:{$0.id==replacing && $0.asset==nil}) else { throw ScrollStitchError.invalidSelection }
                }
                var seen=Set(previous.filter { $0.id != replacing }.compactMap(\.selectionIdentifier))
                let accepted=selections.filter { item in
                    guard let id=item.identifier, !id.isEmpty else { return true }
                    return seen.insert(id).inserted
                }
                if accepted.isEmpty { return nil }
                guard old != nil || (2...20).contains(accepted.count),
                      replacing != nil || previous.count+accepted.count<=20 else { throw ScrollStitchError.invalidSelection }
                let newTask=old == nil
                let manifest: TaskManifest
                if let taskID { manifest=try requireCurrent(taskID) }
                else { manifest=try create(.collage,now:now); old=try readEdit(manifest.taskID) }
                let before=old!
                var next=before; next.imports=previous
                var slots:[ImportBatchSlot]=[]
                for item in accepted {
                    let slotID=replacing ?? item.id
                    let record=ImportRecord(id:slotID,selectionIdentifier:item.identifier?.isEmpty == false ? item.identifier:nil)
                    if let replacing, let index=next.imports.firstIndex(where:{$0.id==replacing}) { next.imports[index]=record }
                    else { next.imports.append(record) }
                    slots.append(ImportBatchSlot(inputID:item.id,itemID:slotID))
                }
                next.assets=next.imports.compactMap(\.asset)
                let batch=ImportBatchState(id:UUID(),itemIDs:slots.map(\.itemID)); next.activeImport=batch
                do {
                    _=try persistEdit(next,old:before,expectedRevision:before.revision,label:replacing == nil ? "添加图片":"重新选择",now:now,force:true)
                } catch {
                    // There was no previous work to preserve in a failed initial creation.
                    if newTask {
                        try? FileManager.default.removeItem(at:taskDirectory(manifest.taskID))
                        try? FileManager.default.removeItem(at:file("current.json"))
                    }
                    throw error
                }
                return ImportBatchAccess(taskID:manifest.taskID,batchID:batch.id,slots:slots,lease:owner)
            }
        }
    }
    public func completeImportItem(taskID: UUID, batchID: UUID, itemID: UUID,
                                   asset: SourceAsset? = nil, issue: ImportIssue? = nil) throws -> EditSnapshot {
        if let asset { try verify(asset,taskID:taskID) }
        return try transaction {
            let old=try readEdit(taskID)
            guard let batch=old.activeImport, batch.id==batchID, batch.itemIDs.contains(itemID),
                  let index=old.imports.firstIndex(where:{$0.id==itemID}), old.imports[index].issue == .loading else {
                throw ScrollStitchError.staleOperation
            }
            guard (asset == nil) != (issue == nil), issue != .loading else { throw ScrollStitchError.invalidSelection }
            var next=old; next.imports[index].asset=asset; next.imports[index].issue=issue
            next.assets=next.imports.compactMap(\.asset)
            return try persistEdit(next,old:old,expectedRevision:old.revision,label:nil,now:old.committedAt!,force:true)
        }
    }
    @discardableResult public func finishImport(taskID: UUID, batchID: UUID) throws -> EditSnapshot {
        try transaction {
            let old=try readEdit(taskID)
            guard old.activeImport?.id==batchID else { throw ScrollStitchError.staleOperation }
            var next=old
            for i in next.imports.indices where next.imports[i].issue == .loading { next.imports[i].issue = .cancelled }
            next.activeImport=nil
            return try persistEdit(next,old:old,expectedRevision:old.revision,label:nil,now:old.committedAt!,force:true)
        }
    }
    /// Copies a picker-owned file while its provider callback is alive; never mutates the original.
    public func importAsset(from source: URL, taskID: UUID, size: PixelSize) throws -> SourceAsset {
        try transaction {
            let manifest = try requireCurrent(taskID)
            guard manifest.kind == .collage, size.pixels <= 48_000_000 else { throw ScrollStitchError.unsupportedInput }
            let directory = try taskDirectory(taskID), id = UUID()
            let temporary = directory.appendingPathComponent("temporary/" + id.uuidString)
            let path = try AssetPath("assets/" + id.uuidString + ".image")
            let destination = try path.resolved(in: directory)
            try FileManager.default.copyItem(at: source, to: temporary)
            do {
                try Self.protect(temporary)
                let digest = try Self.digest(url: temporary)
                try FileManager.default.moveItem(at: temporary, to: destination)
                return SourceAsset(id: id, path: path, size: size, sha256: digest)
            } catch { try? FileManager.default.removeItem(at: temporary); throw error }
        }
    }
    public func acquireShareLease(taskID: UUID) throws -> FileLease {
        try transaction {
            _ = try requireCurrent(taskID)
            return try FileLease(url: file("share-owner.lock"), nonblocking: true)
        }
    }
    /// Isolated diagnostics may use their own stores while excluding capture/cleanup here.
    /// Acquiring these guards never creates a task or updates its interaction timestamp.
    public func acquireDiagnosticLease() throws -> [FileLease] {
        try transaction {
            [try FileLease(url:file("capture-owner.lock"),nonblocking:true),
             try FileLease(url:file("share-owner.lock"),nonblocking:true)]
        }
    }
    /// Returns false when an active owner prevents cleanup; no timer declares a writer dead.
    @discardableResult public func cleanup(taskID: UUID, explicit: Bool, now: Date = Date()) throws -> Bool {
        try transaction {
            guard var manifest = try readCurrent() else { return true }
            guard manifest.taskID == taskID else { throw ScrollStitchError.wrongTask }
            if manifest.kind == .capture, !explicit, !manifest.deleting {
                // Recorded works have no implicit expiry. Read the schema before
                // any cleanup decision, including a persisted pending request.
                _ = try captureSnapshotUnlocked(taskID:taskID,verifyFiles:false)
                return false
            }
            if manifest.kind == .collage, !manifest.deleting, !explicit {
                // Fail closed for corrupt/unknown edit formats; never expire unreadable work.
                let edit=try readEdit(taskID)
                if let committedAt=edit.committedAt { manifest.lastInteractionAt=max(manifest.lastInteractionAt,committedAt) }
            }
            guard explicit || manifest.pendingCleanup || manifest.deleting || now.timeIntervalSince(manifest.lastInteractionAt) >= 86_400 else { return false }
            let owners: [FileLease]
            do {
                owners = [try FileLease(url: file("capture-owner.lock"), nonblocking: true),
                          try FileLease(url: file("share-owner.lock"), nonblocking: true)]
            } catch ScrollStitchError.resourceBusy {
                manifest.pendingCleanup = true; try Self.write(manifest, to: file("current.json")); return false
            }
            return try withExtendedLifetime(owners) {
                manifest.deleting = true; try Self.write(manifest, to: file("current.json"))
                let directory = try taskDirectory(taskID)
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                try FileManager.default.removeItem(at: file("current.json"))
                return true
            }
        }
    }
    // M1 result metadata is additive. Original capture/edit snapshots never migrate.
    private func assertResultRevision(_ result: ResultManifest, allowPendingCleanup: Bool = false) throws {
        try result.validate()
        let manifest=try requireCurrent(result.taskID)
        guard allowPendingCleanup || !manifest.pendingCleanup else { throw ScrollStitchError.staleOperation }
        if manifest.kind == .capture {
            let capture=try captureSnapshotUnlocked(taskID:result.taskID,verifyFiles:false)
            guard capture.sequence == result.revision,
                  capture.phase == .ended || capture.phase == .interrupted else { throw ScrollStitchError.staleOperation }
        } else {
            guard try readEdit(result.taskID).revision == result.revision else { throw ScrollStitchError.staleOperation }
        }
    }
    private func verifyResultFile(_ result: ResultManifest) throws -> URL {
        let url=try result.path.resolved(in:taskDirectory(result.taskID))
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
        guard (attrs[.size] as? NSNumber)?.intValue == result.sizeBytes,
              try Self.digest(url:url) == result.sha256,
              let source=CGImageSourceCreateWithURL(url as CFURL,nil), CGImageSourceGetCount(source)==1,
              let type=CGImageSourceGetType(source) as String?,
              type == (result.format == "png" ? "public.png" : "public.jpeg"),
              let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              props[kCGImagePropertyPixelWidth] as? Int == result.size.width,
              props[kCGImagePropertyPixelHeight] as? Int == result.size.height else { throw ResultExportError.invalidResult }
        return url
    }
    public func publishResult(_ result: ResultManifest) throws {
        let lease=try acquireShareLease(taskID:result.taskID)
        try withExtendedLifetime(lease) {
            try transaction {
                try assertResultRevision(result)
                _=try verifyResultFile(result)
                try fault?(.beforeResultPublish)
                try Self.write(result,to:taskDirectory(result.taskID).appendingPathComponent("result-v1.json"))
            }
        }
    }
    /// Missing, old or corrupt output is a recoverable cache miss; the caller keeps sources.
    public func currentResult(taskID: UUID, selectionFingerprint: String) throws -> ResultManifest? {
        let lease=try acquireShareLease(taskID:taskID)
        return try withExtendedLifetime(lease) {
            try transaction {
                if let set=try? readCaptureResultSet(taskID),set.selectionFingerprint==selectionFingerprint,
                   let result=set.pages.first?.result {
                    do { for page in set.pages {try assertResultRevision(page.result);_=try verifyResultFile(page.result)};return result }
                    catch { return nil }
                }
                let url=try taskDirectory(taskID).appendingPathComponent("result-v1.json")
                guard FileManager.default.fileExists(atPath:url.path) else { return nil }
                do {
                    let result:ResultManifest=try Self.read(url)
                    guard result.taskID == taskID, result.selectionFingerprint == selectionFingerprint else { return nil }
                    try assertResultRevision(result)
                    _=try verifyResultFile(result)
                    return result
                } catch { return nil }
            }
        }
    }
    public func openResult(taskID: UUID, resultID: String) throws -> ResultAccess {
        try openResults(taskID:taskID,resultIDs:[resultID])[0]
    }
    public func openResults(taskID:UUID,resultIDs:[String]) throws -> [ResultAccess] {
        guard !resultIDs.isEmpty,resultIDs.count<=512,Set(resultIDs).count==resultIDs.count else { throw ResultExportError.invalidResult }
        let lease=try acquireShareLease(taskID:taskID)
        return try transaction {
            try resultIDs.map { resultID in
                let result=try publishedResult(taskID:taskID,resultID:resultID)
                guard result.taskID == taskID, result.id == resultID else { throw ScrollStitchError.staleOperation }
                try assertResultRevision(result)
                return try ResultAccess(result:result,url:verifyResultFile(result),lease:lease)
            }
        }
    }
    private func assertAccess(_ access: ResultAccess, allowPendingCleanup: Bool = false) throws {
        guard access.lease.path == (try file("share-owner.lock")).path else { throw ScrollStitchError.wrongTask }
        try assertResultRevision(access.result,allowPendingCleanup:allowPendingCleanup)
        let current=try publishedResult(taskID:access.result.taskID,resultID:access.result.id)
        guard current == access.result else { throw ScrollStitchError.staleOperation }
    }

    private func readCaptureResultSet(_ taskID:UUID) throws -> CaptureResultSet? {
        let url=try taskDirectory(taskID).appendingPathComponent("result-set-v2.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let set:CaptureResultSet=try Self.read(url)
        try set.validate()
        guard set.taskID==taskID else { throw ScrollStitchError.wrongTask }
        return set
    }
    private func publishedResult(taskID:UUID,resultID:String) throws -> ResultManifest {
        if let set=try readCaptureResultSet(taskID),let page=set.pages.first(where:{$0.result.id==resultID}) { return page.result }
        let result:ResultManifest=try Self.read(taskDirectory(taskID).appendingPathComponent("result-v1.json"))
        guard result.id==resultID,result.taskID==taskID else { throw ScrollStitchError.staleOperation }
        return result
    }
    public func captureResultSet(taskID:UUID,selectionFingerprint:String) throws -> CaptureResultSet? {
        try transaction {
            guard let set=try readCaptureResultSet(taskID),set.selectionFingerprint==selectionFingerprint else { return nil }
            let capture=try captureSnapshotUnlocked(taskID:taskID,verifyFiles:false)
            guard capture.sequence==set.revision,capture.phase == .ended || capture.phase == .interrupted else { return nil }
            _=try requireCurrent(taskID)
            for page in set.pages {try assertResultRevision(page.result);_=try verifyResultFile(page.result)}
            return set
        }
    }
    public func publishCaptureResultSet(_ set:CaptureResultSet,using ownedLease:FileLease? = nil) throws {
        try set.validate()
        let lease=try ownedLease ?? acquireShareLease(taskID:set.taskID)
        guard lease.path == (try file("share-owner.lock")).path else { throw ScrollStitchError.wrongTask }
        try withExtendedLifetime(lease) {
            try transaction {
                let current=try requireCurrent(set.taskID)
                guard current.kind == .capture,!current.pendingCleanup else {throw ScrollStitchError.staleOperation}
                let capture=try captureSnapshotUnlocked(taskID:set.taskID,verifyFiles:false)
                guard capture.sequence==set.revision,capture.phase == .ended || capture.phase == .interrupted else {
                    throw ScrollStitchError.staleOperation
                }
                for page in set.pages { try assertResultRevision(page.result);_=try verifyResultFile(page.result) }
                try fault?(.beforeResultPublish)
                try Self.write(set,to:taskDirectory(set.taskID).appendingPathComponent("result-set-v2.json"))
            }
        }
    }
    public func hasCaptureMedia(taskID:UUID) throws -> Bool {
        try transaction {
            if !(try captureSnapshotUnlocked(taskID:taskID,verifyFiles:false)).frames.isEmpty { return true }
            let url=try taskDirectory(taskID).appendingPathComponent("recording/index.json")
            if FileManager.default.fileExists(atPath:url.path) {
                let index=try JSONDecoder().decode(CaptureVideoIndex.self,from:Data(contentsOf:url))
                guard index.version==1 else { throw ScrollStitchError.unsupportedSchema }
                if !index.segments.isEmpty {return true}
            }
            let recording=try AssetPath("recording").resolved(in:taskDirectory(taskID))
            guard FileManager.default.fileExists(atPath:recording.path) else {return false}
            return try FileManager.default.contentsOfDirectory(at:recording,includingPropertiesForKeys:[.fileSizeKey]).contains {
                $0.lastPathComponent.hasSuffix(".partial.mov") && ((try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0
            }
        }
    }
    private func photoLedger(_ id: UUID) throws -> PhotoSaveLedger {
        let url=try taskDirectory(id).appendingPathComponent("photo-save-v1.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return PhotoSaveLedger() }
        let value:PhotoSaveLedger=try Self.read(url)
        guard value.schemaVersion == 1, value.records.allSatisfy({ $0.key == $0.value.resultID }) else {
            throw ScrollStitchError.corruptData
        }
        return value
    }
    public func photoSaveRecord(_ access: ResultAccess) throws -> PhotoSaveRecord? {
        try transaction {
            try assertAccess(access,allowPendingCleanup:true)
            return try photoLedger(access.result.taskID).records[access.result.id]
        }
    }
    public func beginPhotoSave(_ access: ResultAccess, confirmedRepeat: Bool = false) throws -> PhotoSaveRecord {
        try transaction {
            try assertAccess(access)
            var ledger=try photoLedger(access.result.taskID)
            if !confirmedRepeat, let old=ledger.records[access.result.id] {
                if old.phase == .saved { throw ResultExportError.alreadySaved }
                if old.phase == .writing { throw ResultExportError.unconfirmedWrite }
            }
            let record=PhotoSaveRecord(resultID:access.result.id,phase:.writing)
            ledger.records[record.resultID]=record
            try fault?(.beforePhotoSaveIntent)
            try Self.write(ledger,to:taskDirectory(access.result.taskID).appendingPathComponent("photo-save-v1.json"))
            return record
        }
    }
    public func finishPhotoSave(_ access: ResultAccess, operationID: UUID, success: Bool) throws {
        try transaction {
            try assertAccess(access,allowPendingCleanup:true)
            var ledger=try photoLedger(access.result.taskID)
            guard var record=ledger.records[access.result.id], record.operationID == operationID,
                  record.phase == .writing else { throw ScrollStitchError.staleOperation }
            record.phase=success ? .saved : .failed; record.updatedAt=Date()
            ledger.records[record.resultID]=record
            try fault?(.beforePhotoSaveCompletion)
            try Self.write(ledger,to:taskDirectory(access.result.taskID).appendingPathComponent("photo-save-v1.json"))
        }
    }
    public static func digest(data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func digest(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func protect(_ url: URL) throws {
        var mutable = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
    }
    private static func read<T: Decodable>(_ url: URL) throws -> T {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw ScrollStitchError.invalidPath }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        }
        catch let e as ScrollStitchError { throw e }
        catch { throw ScrollStitchError.corruptData }
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try atomicData(encoder.encode(value), to: url)
    }
    private static func atomicData(_ data: Data, to url: URL) throws {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw ScrollStitchError.invalidPath }
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp, options: .withoutOverwriting)
        try protect(temp)
        let handle = try FileHandle(forWritingTo: temp)
        try handle.synchronize(); try handle.close()
        guard rename(temp.path, url.path) == 0 else { throw ScrollStitchError.storageFailure }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }
}
