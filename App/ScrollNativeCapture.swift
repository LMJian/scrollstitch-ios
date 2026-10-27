#if canImport(ScreenCaptureKit)
import UIKit
import CoreImage
import CoreMedia
import ImageIO
@preconcurrency import ScreenCaptureKit

/// One stream, one serial frame writer, one generation. Late callbacks cannot
/// append to a replacement session or complete a different picker request.
@MainActor final class ScrollNativeCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSelected: (() throws -> Void)?
    var onStarted: (() async -> Void)?
    var onStopped: ((Bool) async -> Void)?
    var onFailure: ((String) async -> Void)?
    private let queue = DispatchQueue(label: "com.scrollstitch.capture", qos: .userInitiated)
    nonisolated private let samples = ScrollSampleState()
    private var stream: SCStream?
    private var observer: ScrollPickerObserver?
    private var generation = UUID()
    private var starting = false
    private var stopping = false
    private var streamStopped = false
    private(set) var choosing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pickerBackground: UIBackgroundTaskIdentifier = .invalid
    var idle: Bool { stream == nil && !choosing && !starting && !stopping }

    func present(archive: ScrollFrameArchive) throws {
        guard idle, SCContentSharingPicker.shared.isAvailable else { throw ScrollStitchError.captureActive }
        generation = UUID(); choosing = true; streamStopped = false
        queue.sync { samples.begin(archive: archive, generation: generation) }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false; configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        let observer = ScrollPickerObserver(owner: self, generation: generation)
        self.observer = observer; picker.add(observer); picker.isActive = true
        let token = generation
        pickerBackground = UIApplication.shared.beginBackgroundTask(withName: "ScrollScreenConsent") { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.choosing else { return }
                await self.cancel(message: "共享尚未开始，请再点一次卷轴。")
            }
        }
        picker.present(using: .display)
    }

    func represent() {
        guard choosing, !starting, !stopping else { return }
        SCContentSharingPicker.shared.present(using: .display)
    }

    func waitForPicker() async {
        guard choosing else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func resolvePicker() {
        choosing = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
        if pickerBackground != .invalid { UIApplication.shared.endBackgroundTask(pickerBackground); pickerBackground = .invalid }
    }

    fileprivate func selected(_ selection: ScrollSelectedScreen, generation token: UUID) async {
        guard token == generation, choosing, !starting, !stopping, stream == nil else { return }
        starting = true
        do {
            try onSelected?()
            let configuration = SCStreamConfiguration(); configuration.capturesAudio = false
            let value = SCStream(filter: selection.filter, configuration: configuration, delegate: self)
            stream = value
            queue.sync { samples.activate(value) }
            try value.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await value.startCapture()
            guard token == generation, choosing, starting, !stopping, stream === value else {
                try? await value.stopCapture(); return
            }
            starting = false
            await onStarted?()
            guard token == generation else { return }
            resolvePicker()
        } catch {
            // A cancelled picker can finish startCapture after a replacement
            // session begins. Its failure belongs only to its own generation.
            guard token == generation, choosing, !stopping else { return }
            await cancel(message: "屏幕共享未能开始，原始画面已保留。")
        }
    }

    fileprivate func cancelled(generation token: UUID, failed: Bool = false) async {
        guard token == generation, choosing else { return }
        await cancel(message: failed ? "系统未能打开共享面板。" : "已取消屏幕共享")
    }

    func togglePage() throws -> (paused: Bool, page: Int) {
        guard stream != nil, !starting, !stopping else { throw ScrollStitchError.captureActive }
        return try queue.sync {
            guard let archive = samples.archive else { throw ScrollStitchError.wrongTask }
            return (try archive.togglePage(), archive.page)
        }
    }

    func stop(complete: Bool) async throws {
        guard !stopping else { return }
        stopping = true
        defer {
            // Even a failed metadata write must release the capture owner so
            // recovery and subsequent sessions are not permanently locked out.
            queue.sync { samples.reset() }
            stopping = false; starting = false; resolvePicker()
        }
        // Draining the sample queue before the first await establishes the exact
        // finish boundary. No timer-based lead-in or trailing-frame deletion.
        let archive = queue.sync { samples.seal() }
        let prior = stream; stream = nil
        removePicker()
        var failure: Error?
        if !streamStopped { do { try await prior?.stopCapture() } catch { failure = error } }
        try archive?.finish(complete: complete && failure == nil)
        if let failure { throw failure }
    }

    func cancel(message: String) async {
        guard !stopping else { return }
        try? await stop(complete: false)
        await onFailure?(message)
    }

    private func removePicker() {
        if let observer { SCContentSharingPicker.shared.remove(observer) }
        observer = nil; SCContentSharingPicker.shared.isActive = false
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let token = samples.token(for: stream) else { return }
        do { try samples.consume(buffer) }
        catch {
            samples.archive?.seal()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.stream != nil, !self.stopping else { return }
                await self.cancel(message: "画面保存中断，已保留现有素材。请检查剩余空间。")
            }
        }
    }

    nonisolated func stream(_ value: SCStream, didStopWithError error: any Error) {
        let identifier = ObjectIdentifier(value)
        let userStopped = (error as NSError).domain == SCStreamErrorDomain &&
            (error as NSError).code == SCStreamError.Code.userStopped.rawValue
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == identifier, !self.stopping else { return }
            self.streamStopped = true
            await self.onStopped?(userStopped)
        }
    }

    static func topCropRatio() -> Double {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        guard let window, window.bounds.height > 0 else { return 0.075 }
        return min(0.075, max(0, window.safeAreaInsets.top / window.bounds.height))
    }
}

fileprivate struct ScrollSelectedScreen: @unchecked Sendable { let filter: SCContentFilter }
private final class ScrollPickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private weak var owner: ScrollNativeCapture?
    private let generation: UUID
    init(owner: ScrollNativeCapture, generation: UUID) { self.owner = owner; self.generation = generation }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = ScrollSelectedScreen(filter: filter)
        Task { @MainActor [weak owner, generation] in await owner?.selected(selection, generation: generation) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak owner, generation] in await owner?.cancelled(generation: generation) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak owner, generation] in await owner?.cancelled(generation: generation, failed: true) }
    }
}

/// Accessed only by the serial sample queue, including activation and sealing.
private final class ScrollSampleState: @unchecked Sendable {
    var archive: ScrollFrameArchive?
    private var streamID: ObjectIdentifier?
    private var generation: UUID?
    private let context = CIContext(options: [.cacheIntermediates: false])
    func begin(archive: ScrollFrameArchive, generation: UUID) { self.archive = archive; self.generation = generation }
    func activate(_ stream: SCStream) { streamID = ObjectIdentifier(stream) }
    func token(for stream: SCStream) -> UUID? { streamID == ObjectIdentifier(stream) ? generation : nil }
    func seal() -> ScrollFrameArchive? { streamID = nil; generation = nil; archive?.seal(); return archive }
    func reset() { archive = nil }
    func consume(_ buffer: CMSampleBuffer) throws {
        guard let archive, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard archive.accepts(pts: time, hostForeground: ScrollHostVisibility.shared.isForeground) else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        if let raw = info?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete && status != .started { return }
        try autoreleasepool {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
            var image = CIImage(cvPixelBuffer: pixels)
            if let raw = info?[.videoOrientation] as? NSNumber,
               let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value) { image = image.oriented(orientation) }
            guard let cg = context.createCGImage(image, from: image.extent),
                  let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) else { throw ScrollStitchError.storageFailure }
            try archive.append(jpeg: jpeg, size: PixelSize(width: cg.width, height: cg.height), pts: time)
        }
    }
}

final class ScrollHostVisibility: @unchecked Sendable {
    static let shared = ScrollHostVisibility()
    private let lock = NSLock()
    private var foreground = false
    var isForeground: Bool { lock.lock(); defer { lock.unlock() }; return foreground }
    func set(_ value: Bool) { lock.lock(); foreground = value; lock.unlock() }
}
#endif
