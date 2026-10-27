#if canImport(ScreenCaptureKit)
import SwiftUI
import UIKit
@preconcurrency import ActivityKit
import UserNotifications
import WidgetKit
@preconcurrency import BackgroundTasks

/// App-owned orchestration survives view dismissal. Native capture only emits
/// committed frames; computation and the durable Photos ledger own completion.
@MainActor final class ScrollCaptureCoordinator: NSObject, ObservableObject {
    static let shared = ScrollCaptureCoordinator()
    @Published private(set) var session: ScrollSession?
    @Published private(set) var works: [ScrollSession] = []
    @Published private(set) var message = "从控制中心开始滚动截图"
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestThumbnail: UIImage?
    @Published private(set) var latestResults: [ResultManifest] = []
    @Published var openedWork: ScrollSession?
    @Published var selectedTab = 0
    @Published var axis: ScrollAxis = .vertical {
        didSet { UserDefaults.standard.set(axis.rawValue, forKey: "scroll.axis") }
    }
    @Published var keepsStatusBar = false {
        didSet { UserDefaults.standard.set(keepsStatusBar, forKey: "scroll.keepsStatusBar") }
    }
    private let native = ScrollNativeCapture()
    private var library: ScrollLibrary?
    private var store: TaskStore?
    private var owner: FileLease?
    private var activity: Activity<ScrollActivityAttributes>?
    private var worker: Task<Void, Never>?
    private var computeCancellation: WorkCancellation?
    private var scheduledTask: BGProcessingTask?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var backgroundGeneration = UUID()
    private var interrupted = false
    private var pendingFinish = false
    private var operation = false
    private let photos = PhotoExportController(writer: PhotoKitWriter())

    override private init() {
        super.init()
        axis = ScrollAxis(rawValue: UserDefaults.standard.string(forKey: "scroll.axis") ?? "") ?? .vertical
        keepsStatusBar = UserDefaults.standard.bool(forKey: "scroll.keepsStatusBar")
        native.onSelected = { [weak self] in try self?.transition(.selected) }
        native.onStarted = { [weak self] in
            guard let self else { return }
            do {
                try self.transition(.recordingStarted)
                await self.announce("收起系统提示后，沿选定方向缓慢滚动")
            } catch { await self.native.cancel(message: "无法保存本次截图状态。") }
        }
        native.onStopped = { [weak self] userStopped in
            guard let self else { return }
            self.interrupted = !userStopped
            await self.finish()
        }
        native.onFailure = { [weak self] message in
            self?.owner = nil
            await self?.fail(message)
        }
        do { if UIApplication.shared.isProtectedDataAvailable { works = try openLibrary().sessions() } }
        catch { errorMessage = "无法读取作品，现有文件已保留。" }
    }

    private func openLibrary() throws -> ScrollLibrary {
        if let library { return library }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ScrollStitchAppGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ScrollStitchError.storageFailure
        }
        let value = try ScrollLibrary(root: root.appendingPathComponent("Library/ScrollStitch/scrolls"))
        library = value; return value
    }
    var active: Bool { session?.phase.unfinished == true }

    func toggle() async {
        if native.choosing { native.represent(); await native.waitForPicker(); return }
        if let phase = session?.phase, [.starting, .recording, .pausing, .paused].contains(phase) {
            await finish(); return
        }
        guard !operation, !active, worker == nil, native.idle else { return }
        operation = true
        await recover()
        guard !active else { releaseOperation(); return }
        do {
            let library = try openLibrary()
            let (value, store, lease) = try library.begin(axis: axis)
            session = value; self.store = store; owner = lease
            interrupted = false; pendingFinish = false; errorMessage = nil; latestThumbnail = nil; latestResults = []
            let archive = try ScrollFrameArchive(store: store, taskID: value.taskID, owner: lease,
                options: ScrollCaptureOptions(axis: axis, keepsStatusBar: keepsStatusBar),
                topCropRatio: ScrollNativeCapture.topCropRatio())
            try native.present(archive: archive)
            await announce("请确认共享整个屏幕")
            releaseOperation()
            await native.waitForPicker()
        } catch {
            releaseOperation()
            if let session, let store, let owner { try? store.finishCapture(taskID: session.taskID, owner: owner, reason: .unknown) }
            owner = nil
            await fail("暂时无法开始共享。请结束其他录屏后重试。")
        }
    }

    private func transition(_ event: ScrollEvent) throws {
        guard var value = session, let library else { throw ScrollStitchError.wrongTask }
        try value.apply(event); try library.save(value); session = value
    }
    private func releaseOperation() {
        operation = false
        if pendingFinish {
            pendingFinish = false
            let id = session?.id
            Task {
                guard self.session?.id == id else { return }
                await finish()
            }
        }
    }
    func nextPage() async {
        guard !operation, let phase = session?.phase, phase == .recording || phase == .paused else { return }
        operation = true
        defer { releaseOperation() }
        do {
            let state = try native.togglePage()
            if state.paused {
                try transition(.pagePaused(state.page))
                await announce("已暂停，换好页面后点继续")
            } else {
                try transition(.pageResumed(state.page))
                await announce("继续截图，收起面板后缓慢滚动")
            }
        } catch { await native.cancel(message: "换页未完成，原始画面已保留。") }
    }
    func finish() async {
        if operation {
            if let phase = session?.phase, [.starting, .recording, .pausing, .paused].contains(phase) { pendingFinish = true }
            return
        }
        guard let phase = session?.phase, [.recording, .paused, .starting].contains(phase) else { return }
        operation = true; defer { releaseOperation() }
        beginBackground()
        do {
            try transition(.finish)
            await announce("正在整理长图…")
            try await native.stop(complete: !interrupted)
            owner = nil
            try transition(.inputSealed)
            launchProcessing()
        } catch {
            owner = nil
            await fail("画面未能完整封存，原始素材已保留。")
        }
    }
    private func launchProcessing() {
        guard worker == nil,let session,let store else {return}
        let cancellation=WorkCancellation();computeCancellation=cancellation
        // Register recovery before computation begins, so process suspension
        // cannot require a view to replay a one-shot "generate" flag.
        try? ScrollBackground.enqueue()
        beginBackground()
        worker=Task { [weak self] in
            guard let self else {return}
            defer {
                self.worker=nil;self.computeCancellation=nil;self.endBackground()
                self.scheduledTask?.setTaskCompleted(success:self.session?.phase == .saved)
                self.scheduledTask=nil
                if cancellation.isCancelled,UIApplication.shared.applicationState == .active {
                    Task {await self.recover()}
                }
            }
            do {
                let set=try await Task.detached(priority:.userInitiated) {
                        try await CapturePipeline.resume(store:store,taskID:session.taskID,
                            selectionFingerprint:TaskStore.digest(data:Data(session.id.uuidString.utf8)),
                            cancelled:{cancellation.isCancelled},
                            progress:{text in Task { @MainActor [weak self] in
                                await self?.processingProgress(text,sessionID:session.id)
                            }})
                    }.value
                guard set.readyForPhotoSave else {
                    throw CaptureProcessingError.invalid(set.gaps.first ?? "没有找到可完整连接的内容。")
                }
                if self.session?.phase == .processing {try self.transition(.reconstructed)}
                await self.announce("正在保存到照片…")
                let results=set.pages.map(\.result)
                let count=await self.photos.saveAll(store:store,results:results,
                    requestPermission:UIApplication.shared.applicationState == .active,
                    cancelled:{cancellation.isCancelled})
                if count==results.count {
                    try self.transition(.photosSaved(count));self.latestResults=results
                    self.recordExecution("photos-saved",detail:String(count))
                    ScrollBackground.cancel()
                    if let first=results.first,
                       let image=try? await Task.detached(operation:{try ImageDecoder.normalized(first.path.resolved(in:store.taskDirectory(first.taskID)),maxDimension:1600)}).value {
                        self.latestThumbnail=UIImage(cgImage:image)
                    }
                    await self.announce("已保存到照片")
                    await self.notifySaved(session:session,count:count)
                } else if self.photos.state == .unknown {
                    try self.transition(.uncertainSave);await self.announce("保存结果待确认，未重复写入")
                } else if self.photos.state == .denied || self.photos.state == .restricted {
                    try self.transition(.permissionDenied);await self.announce("请允许添加照片，长图已保留")
                } else if cancellation.isCancelled {
                    throw ScrollStitchError.cancelled
                } else {await self.fail("保存未完成，长图已保留。")}
                self.works=(try? self.library?.sessions()) ?? self.works
            } catch ScrollStitchError.cancelled {
                self.recordExecution("processing-suspended")
                try? ScrollBackground.enqueue()
                await self.announce("整理进度已保留，等待系统继续处理")
            } catch {
                if !UIApplication.shared.isProtectedDataAvailable {
                    try? ScrollBackground.enqueue()
                    await self.announce("整理进度已保留，设备解锁后继续")
                } else {await self.fail(error.localizedDescription)}
            }
        }
    }
    func protectedDataUnavailable() {
        computeCancellation?.cancel(reason:.background)
        if session?.phase == .processing || session?.phase == .saving {try? ScrollBackground.enqueue()}
    }
    func resumeBackground(_ task:BGProcessingTask) async {
        guard scheduledTask == nil else {task.setTaskCompleted(success:false);return}
        guard UIApplication.shared.isProtectedDataAvailable else {
            try? ScrollBackground.enqueue();task.setTaskCompleted(success:false);return
        }
        scheduledTask=task
        recordExecution("deferred-running")
        let taskID = ObjectIdentifier(task)
        task.expirationHandler={ @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.scheduledTask.map(ObjectIdentifier.init) == taskID else { return }
                self.computeCancellation?.cancel(reason:.background)
            }
        }
        await recover()
        if worker == nil {task.setTaskCompleted(success:session?.phase == .saved);scheduledTask=nil}
    }
    private func processingProgress(_ text:String,sessionID:UUID) async {
        guard session?.id==sessionID,session?.phase == .processing else {return}
        await announce(text)
    }
    private func recordExecution(_ event:String,detail:String? = nil) {
        guard let store,let session,let directory=try? store.taskDirectory(session.taskID) else {return}
        let url=directory.appendingPathComponent("background-execution.jsonl")
        var entry:[String:Any]=["event":event,"uptime":ProcessInfo.processInfo.systemUptime,
                               "applicationState":UIApplication.shared.applicationState.rawValue]
        if let detail {entry["detail"]=detail}
        guard var bytes=try? JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys]) else {return}
        bytes.append(10)
        if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil)}
        if let file=try? FileHandle(forWritingTo:url) {
            defer {try? file.close()}
            try? file.seekToEnd();try? file.write(contentsOf:bytes);try? file.synchronize()
            try? protectCaptureFile(url)
        }
    }
    /// Called on launch/foreground. Compute retries are safe; Photos uses its durable ledger.
    func recover() async {
        guard worker == nil,native.idle,owner == nil else {return}
        guard UIApplication.shared.isProtectedDataAvailable else {return}
        do {
            let library=try openLibrary()
            works=try library.sessions()
            guard var value=works.first(where:{$0.phase.unfinished}) else {
                for previous in Activity<ScrollActivityAttributes>.activities {
                    await previous.end(nil,dismissalPolicy:.immediate)
                }
                activity=nil;refreshControls(.idle);return
            }
            for previous in Activity<ScrollActivityAttributes>.activities {
                if previous.attributes.sessionID==value.id.uuidString {activity=previous}
                else {await previous.end(nil,dismissalPolicy:.immediate)}
            }
            guard worker == nil, native.idle, owner == nil else { return }
            let store=try library.store(for:value.id)
            let set=try store.captureResultSet(taskID:value.taskID,selectionFingerprint:TaskStore.digest(data:Data(value.id.uuidString.utf8)))
            var unknown=false
            for result in set?.pages.map(\.result) ?? [] {
                let access=try store.openResult(taskID:value.taskID,resultID:result.id)
                if try store.photoSaveRecord(access)?.phase == .writing {unknown=true}
            }
            value.recover(hasResult:set?.readyForPhotoSave == true,hasUncertainPhotoWrite:unknown)
            try library.save(value);self.session=value;self.store=store
            if value.phase == .processing || value.phase == .saving {launchProcessing()}
            else {await announce(value.phase == .saveUncertain ? "保存结果待确认，未重复写入":"录制被中断，原始素材已保留")}
        } catch {errorMessage="恢复未完成，现有文件已保留。"}
    }
    func openWork(_ id:UUID) {
        works=(try? library?.sessions()) ?? works
        selectedTab=0;openedWork=works.first(where:{$0.id==id})
    }
    func dismissSavedPreview() { latestThumbnail = nil }
    /// Explicit recovery is available only for a sealed input or completed
    /// result. The durable photo ledger still blocks uncertain writes.
    func retry(_ work:ScrollSession) async {
        guard !active,worker == nil,let library else {return}
        do {
            let store=try library.store(for:work.id)
            let result=try store.captureResultSet(taskID:work.taskID,
                selectionFingerprint:TaskStore.digest(data:Data(work.id.uuidString.utf8)))
            let inputURL=try store.taskDirectory(work.taskID).appendingPathComponent("scroll-frames.json")
            guard result?.readyForPhotoSave == true || (try? JSONDecoder().decode(ScrollFrameInput.self,from:Data(contentsOf:inputURL)).complete)==true else {
                errorMessage="录制未完整封存，原始素材已保留，可重新开始截图。";return
            }
            guard var value=try library.sessions().first(where:{$0.id==work.id}) else {throw ScrollStitchError.wrongTask}
            try value.retryKnownFailure(hasResult:result?.readyForPhotoSave == true)
            try library.save(value);session=value;self.store=store;errorMessage=nil
            launchProcessing()
        } catch {errorMessage="当前记录不能自动重试，原始素材和保存记录已保留。"}
    }
    private func beginBackground() {
        guard background == .invalid else {return}
        let token = UUID(); backgroundGeneration = token
        background=UIApplication.shared.beginBackgroundTask(withName:"CompleteScrollScreenshot") { [weak self] in
            Task { @MainActor in
                guard let self, self.backgroundGeneration == token else { return }
                if self.scheduledTask == nil {
                    self.computeCancellation?.cancel(reason:.background)
                }
                self.endBackground()
            }
        }
    }
    private func endBackground() {
        backgroundGeneration = UUID()
        if background != .invalid {UIApplication.shared.endBackgroundTask(background);background = .invalid}
    }
    private func announce(_ text:String) async {
        message=text
        guard let session else {return}
        refreshControls(ScrollControlPhase(sessionPhase:session.phase.rawValue))
        let content=ActivityContent(state:ScrollActivityAttributes.ContentState(phase:session.phase.rawValue,message:text,page:session.page),staleDate:nil)
        if let activity {
            if session.phase.unfinished {await activity.update(content)}
            else {await activity.end(content,dismissalPolicy:.after(Date().addingTimeInterval(15)));self.activity=nil}
        } else if session.phase.unfinished,ActivityAuthorizationInfo().areActivitiesEnabled {
            activity=try? Activity.request(attributes:ScrollActivityAttributes(sessionID:session.id.uuidString),content:content,pushType:nil)
        }
    }
    private func refreshControls(_ phase: ScrollControlPhase) {
        ScrollControlState.publish(phase)
        ControlCenter.shared.reloadControls(ofKind: ScrollControlState.mainKind)
        ControlCenter.shared.reloadControls(ofKind: ScrollControlState.pageKind)
    }
    private func notifySaved(session:ScrollSession,count:Int) async {
        let center=UNUserNotificationCenter.current(),settings=await center.notificationSettings()
        guard [.authorized,.provisional,.ephemeral].contains(settings.authorizationStatus),
              UIApplication.shared.applicationState != .active else {return}
        let content=UNMutableNotificationContent()
        content.title="长图已保存";content.body="点击查看刚刚生成的 \(count) 张图片"
        content.userInfo=["scrollSession":session.id.uuidString]
        try? await center.add(UNNotificationRequest(identifier:"scroll.saved."+session.id.uuidString,content:content,trigger:nil))
    }
    private func fail(_ text:String) async {
        try? transition(.failed(text));errorMessage=text
        works=(try? library?.sessions()) ?? works
        await announce(text);endBackground()
    }
}
#endif
