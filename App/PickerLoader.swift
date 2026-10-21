import Foundation
import UniformTypeIdentifiers

struct PickerInput: @unchecked Sendable {
    let id: UUID
    let identifier: String?
    let provider: NSItemProvider
}

/// Cancellation is shared by the UI, provider callbacks and synchronous image work.
final class WorkCancellation: @unchecked Sendable {
    enum Reason: Sendable { case user, memoryPressure, background }
    private let lock = NSLock()
    private var stopReason: Reason?
    private var progressText: String?
    var progress: String? { lock.lock();defer { lock.unlock() };return progressText }
    func updateProgress(_ text:String) { lock.lock();progressText=text;lock.unlock() }
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    var reason: Reason? { lock.lock(); defer { lock.unlock() }; return stopReason }
    var isCancelled: Bool { reason != nil }
    func check() throws { if isCancelled { throw ScrollStitchError.cancelled } }
    func cancel(reason: Reason = .user) {
        lock.lock()
        // Retain the first observed cause, including when a late UI cancellation arrives.
        if stopReason == nil { stopReason = reason }
        let actions = Array(callbacks.values); callbacks.removeAll(); lock.unlock()
        actions.forEach { $0() }
    }
    func register(_ action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(); lock.lock(); let run = stopReason != nil
        if !run { callbacks[id] = action }; lock.unlock()
        if run { action() }; return id
    }
    func unregister(_ id: UUID) { lock.lock(); callbacks[id] = nil; lock.unlock() }
}

private final class ProviderRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SourceAsset, any Error>?
    private var progress: Progress?
    private var ended = false
    init(_ continuation: CheckedContinuation<SourceAsset, any Error>) { self.continuation = continuation }
    func setProgress(_ progress: Progress) {
        lock.lock(); self.progress = progress; let cancel = ended; lock.unlock()
        if cancel { progress.cancel() }
    }
    func finish(_ result: Result<SourceAsset, any Error>) {
        lock.lock(); guard !ended else { lock.unlock(); return }
        ended = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock(); let progress = self.progress; lock.unlock()
        finish(.failure(ScrollStitchError.cancelled)); progress?.cancel()
    }
}

enum PickerLoader {
    static func ingest(_ input: PickerInput, store: TaskStore, taskID: UUID, cancellation: WorkCancellation, retaining access: ImportBatchAccess? = nil) async throws -> SourceAsset {
        try cancellation.check()
        return try await withCheckedThrowingContinuation { continuation in
            let request = ProviderRequest(continuation)
            let registration = cancellation.register { request.cancel() }
            if cancellation.isCancelled { cancellation.unregister(registration); return }
            let requiresOwner=access != nil
            let progress = input.provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak access] url, error in
                // Pending provider callbacks do not keep a cancelled batch's lease alive.
                // A callback already copying a file retains the owner until its copy ends.
                let callbackOwner=access
                defer { cancellation.unregister(registration); withExtendedLifetime(callbackOwner) {} }
                do {
                    guard !requiresOwner || callbackOwner != nil else { throw ScrollStitchError.cancelled }
                    try cancellation.check()
                    guard error == nil, let url else { throw ScrollStitchError.unsupportedInput }
                    // Provider URL lifetime ends on callback return: inspect and copy here.
                    let asset = try ImageImporter.ingest(url, store: store, taskID: taskID)
                    try cancellation.check()
                    request.finish(.success(asset))
                } catch { request.finish(.failure(error)) }
            }
            request.setProgress(progress)
        }
    }
}

/// Shared by the actual picker UI and isolated provider diagnostics.
enum PickerBatchLoader {
    static func ingest(_ inputs: [PickerInput], store: TaskStore, interactionAt: Date,
                       cancellation: WorkCancellation, taskID: UUID? = nil,
                       expectedRevision: UInt64? = nil, replacing: UUID? = nil) async throws -> TaskManifest {
        try cancellation.check()
        let access=try store.beginImport(taskID:taskID,expectedRevision:expectedRevision,replacing:replacing,
            selections:inputs.map { ImportSelection(id:$0.id,identifier:$0.identifier) },now:interactionAt)
        guard let access else {
            guard let current=try store.current() else { throw ScrollStitchError.invalidSelection }
            return current
        }
        defer { withExtendedLifetime(access) {} }
        do {
            for (index,slot) in access.slots.enumerated() {
                if cancellation.isCancelled { break }
                guard let input=inputs.first(where:{$0.id==slot.inputID}) else { throw ScrollStitchError.invalidSelection }
                cancellation.updateProgress("正在添加图片 \(index+1) / \(access.slots.count)…")
                let asset: SourceAsset?, issue: ImportIssue?
                do {
                    asset=try await PickerLoader.ingest(input,store:store,taskID:access.taskID,cancellation:cancellation,retaining:access)
                    issue=nil
                } catch {
                    asset=nil
                    issue=cancellation.isCancelled ? .cancelled : ((error as? ScrollStitchError) == .budgetExceeded ? .tooLarge:.unavailable)
                }
                if cancellation.isCancelled { break }
                _=try store.completeImportItem(taskID:access.taskID,batchID:access.batchID,itemID:slot.itemID,asset:asset,issue:issue)
            }
            _=try store.finishImport(taskID:access.taskID,batchID:access.batchID)
        } catch {
            _=try? store.finishImport(taskID:access.taskID,batchID:access.batchID)
            throw error
        }
        guard let manifest=try store.current(), manifest.taskID==access.taskID else { throw ScrollStitchError.staleOperation }
        return manifest
    }
}
