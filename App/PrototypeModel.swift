import SwiftUI
import UIKit
import Darwin

typealias PrototypeSnapshot = WorkspaceSnapshot
struct AnalysisResult: Sendable {
    let decision: LayoutDecision?
    let diagnostics: String
}
struct RenderResult: @unchecked Sendable {
    let artifact: ExportArtifact
    let result: ResultManifest
    let photoRecord: PhotoSaveRecord?
    let unreadableSave: Bool
    let preview: CGImage
    let elapsed: Double
    let maximumResidentBytes: Int
}
struct RestoredResult: @unchecked Sendable {
    var captureSet:CaptureResultSet?
    var pageIndex=0
    var elapsed:Double?
    let result: ResultManifest?
    let image: CGImage?
    let record: PhotoSaveRecord?
    let unreadableSave: Bool
    var preparationSummary: String?
}
struct ThumbnailResult: @unchecked Sendable { let images: [UUID:CGImage] }
enum PrototypeResult: Sendable {
    case collagePreview(CGImage, UUID)
    case thumbnails(ThumbnailResult)
    case restored(RestoredResult)
    case editFailed(PrototypeSnapshot?, ScrollStitchError)
    case snapshot(PrototypeSnapshot)
    case analysis(AnalysisResult)
    case rendered(RenderResult)
    case cleared(Bool)
    case diagnostic(DiagnosticExport)
    case inputDiagnostic(InputDiagnosticResult)
}

@MainActor final class PrototypeModel: ObservableObject {
    @Published var snapshot = PrototypeSnapshot(manifest:nil, edit:nil, capture:nil)
    @Published var busy = false
    @Published private(set) var operationStartedAt: Date?
    private var progressWorker: Task<Void,Never>?
    @Published var status = "正在读取本地任务…"
    @Published var errorMessage: String?
    @Published var proposal: CompositionPlan?
    @Published var downscale: CompositionPlan?
    @Published var preview: UIImage?
    @Published var artifact: ExportArtifact?
    @Published var result: ResultManifest?
    @Published private(set) var captureResultSet:CaptureResultSet?
    @Published private(set) var capturePageIndex=0
    @Published var photoState: PhotoExportState = .ready
    @Published var imageShare: ImageShareSession?
    @Published var preparingExport=false
    @Published private(set) var savingAllPages=false
    private var cancelPageSave=false
    @Published var thumbnails: [UUID:UIImage]=[:]
    @Published var collagePreview: UIImage?
    @Published var collagePreviewAssetID: UUID?
    @Published var needsAdjustment=false
    @Published private(set) var automaticallyPrepareCapture=true
    @Published var shareFeedback: String?
    private var generationFormat: ImageFormat?
    var isGenerating: Bool { generationFormat != nil || (busy && status == "正在生成图片…") }
    private let photoController=PhotoExportController(writer:PhotoKitWriter())
    var operationLocked: Bool { busy || preparingExport || photoController.inFlight || imageShare != nil || diagnostic != nil }
    var isLegacyCapture: Bool { snapshot.manifest?.kind == .capture }
    var canEdit: Bool {
        !isLegacyCapture && !operationLocked && snapshot.manifest != nil && snapshot.manifest?.pendingCleanup != true && snapshot.edit?.activeImport == nil &&
        (snapshot.capture == nil || snapshot.capture?.phase == .ended || snapshot.capture?.phase == .interrupted)
    }
    @Published var analysis = ""
    @Published var metrics = ""
    @Published var inputDiagnosticSummary = ""
    @Published var storeReady = false
    @Published var diagnostic: DiagnosticExport?
    @Published private(set) var captureFirst = 0
    @Published private(set) var captureLast = 0
    @Published private(set) var cropTop = 0
    @Published private(set) var cropBottom = 0
    @Published private(set) var cropLeft = 0
    @Published private(set) var cropRight = 0
    @Published var capturePreview: UIImage?
    @Published var capturePreviewOrdinal = 0
    private var lastStage = "read"
    private var lastErrorCode = "none"
    private var lastRenderSeconds: Double?
    private var store: TaskStore?
    private var activeID: UUID?
    private var cancellation: WorkCancellation?
    private var worker: Task<Void, Never>?
    private var measuring = false
    private var previousIdleTimerSetting: Bool?
    private var launchDiagnosticConsumed=false
    private var fixtureIdleTimerSetting:Bool?
    // Explicit local operator mode; normal launches always use the original store.
    @Published private(set) var fixtureName=OperatorFixtureContext.resolve(arguments:ProcessInfo.processInfo.arguments)
    private var selectionKey: String { fixtureName.map { "m1FixtureSelection."+$0 } ?? "captureSelection" }

    init() {
        photoController.onChange = { [weak self] state in
            guard let self else { return }
            self.photoState=state
        }
        do {
            guard let group = Bundle.main.object(forInfoDictionaryKey:"ScrollStitchAppGroup") as? String,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group) else {
                status = "共享容器不可用。请先配置 App Group 与签名。"; return
            }
            if let fixtureName {
                store=try TaskStore(root:container.appendingPathComponent("Library/ScrollStitchM1Fixtures/"+fixtureName))
            } else { store = try TaskStore.inAppGroup(container) }
            if fixtureName != nil {
                fixtureIdleTimerSetting=UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled=true
            }
            storeReady = true; refresh()
        } catch { report(error) }
    }
    func returnToOriginalWork() {
        guard !operationLocked, fixtureName != nil else { return }
        do {
            guard let group=Bundle.main.object(forInfoDictionaryKey:"ScrollStitchAppGroup") as? String,
                  let container=FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group) else {
                throw ScrollStitchError.storageFailure
            }
            let original=try TaskStore.inAppGroup(container)
            _=OperatorFixtureContext.resolve(arguments:["--m1-production"])
            fixtureName=nil;store=original
            if let fixtureIdleTimerSetting { UIApplication.shared.isIdleTimerDisabled=fixtureIdleTimerSetting;self.fixtureIdleTimerSetting=nil }
            clearOutput();snapshot=PrototypeSnapshot(manifest:nil,edit:nil,capture:nil)
            capturePreview=nil;thumbnails=[:];refresh()
        } catch { report(error) }
    }
    nonisolated private static func read(_ store: TaskStore) throws -> PrototypeSnapshot {
        try WorkspaceRecovery.read(store)
    }
    private func clearOutput() {
        captureResultSet=nil;capturePageIndex=0
        proposal=nil; downscale=nil; preview=nil; artifact=nil; result=nil; analysis=""; metrics=""; shareFeedback=nil
        needsAdjustment=false
        photoController.restore(nil)
    }
    private func launch(_ label: String, operation: @escaping @Sendable (WorkCancellation) async throws -> PrototypeResult) {
        guard !operationLocked else { return }
        let id = UUID(), flag = WorkCancellation()
        activeID = id; cancellation = flag; busy = true; status = label; errorMessage = nil
        operationStartedAt=Date()
        // Cover the short cooperative unwind before releasing any shared-container lock.
        // Work is cancelled immediately on leaving the foreground, not kept running there.
        let background=UIApplication.shared.beginBackgroundTask(withName:"Finish local image work") {
            flag.cancel(reason:.background)
        }
        progressWorker=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(250)) } catch { break }
                guard let self,self.activeID==id else { break }
                if !flag.isCancelled,let progress=flag.progress { self.status=progress }
            }
        }
        worker = Task { [weak self] in
            let result = await Task.detached(priority:.userInitiated) { () -> Result<PrototypeResult, any Error> in
                do { return .success(try await operation(flag)) } catch { return .failure(error) }
            }.value
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            guard let self, self.activeID == id else { return }
            self.progressWorker?.cancel();self.progressWorker=nil;self.operationStartedAt=nil
            if let previous = self.previousIdleTimerSetting {
                UIApplication.shared.isIdleTimerDisabled = previous
                self.previousIdleTimerSetting = nil
            }
            self.measuring = false
            self.busy = false; self.worker = nil; self.cancellation = nil; self.activeID = nil
            if flag.isCancelled {
                self.generationFormat=nil
                if case .success(.snapshot(let snapshot)) = result { self.apply(.snapshot(snapshot)) }
                if case .success(.editFailed(let snapshot,_)) = result {
                    if let snapshot { self.apply(.snapshot(snapshot)) } else { self.clearOutput() }
                }
                if flag.reason == .memoryPressure { self.status = "系统内存紧张，处理已停止。已提交素材已保留，请刷新查看。" }
                else if flag.reason == .background {
                    self.status="处理已暂停，原始素材已保留。返回后可继续生成。"
                } else { self.report(ScrollStitchError.cancelled) }
                if flag.reason == .background, UIApplication.shared.applicationState == .active { self.refresh() }
                return
            }
            switch result {
            case .success(let value): self.apply(value)
            case .failure(let error): self.report(error)
            }
        }
    }
    private func apply(_ result: PrototypeResult) {
        switch result {
        case .collagePreview(let image,let id):
            collagePreview=UIImage(cgImage:image);collagePreviewAssetID=id
        case .thumbnails(let loaded):
            thumbnails=loaded.images.mapValues { UIImage(cgImage:$0) }
        case .inputDiagnostic(let result):
            status=result.complete ? (result.offlineVerified ? "本机输入与离线诊断已完成，待审阅报告。" : "本机输入诊断已完成，待审阅报告。") : "本机输入诊断已停止，记录已保留。"
            metrics=result.complete ? (result.offlineVerified ? "失败项、生成保护及离线输出已核对。" : "失败项与生成保护已核对；本次未验证离线条件。") :
                (result.stopReason == "offline_required" ? "系统仍报告网络可用，尚未开始图片检查。请保留记录，不要反复点击。" : "诊断原因：\(result.stopReason)")
            inputDiagnosticSummary=status+"\n"+metrics
        case .diagnostic(let export): diagnostic = export; status = "诊断文件已准备，由你选择保存位置"
        case .restored(let loaded):
            generationFormat=nil
            captureResultSet=loaded.captureSet;capturePageIndex=loaded.pageIndex
            if let descriptor=loaded.result {
                guard isCurrentResult(descriptor) else { report(ScrollStitchError.staleOperation);return }
            }
            self.result=loaded.result
            preview=loaded.image.map { UIImage(cgImage:$0) }
            if let r=loaded.result, let store, let directory=try? store.taskDirectory(r.taskID), let url=try? r.path.resolved(in:directory) {
                artifact=ExportArtifact(taskID:r.taskID,revision:r.revision,url:url,size:r.size,sizeBytes:r.sizeBytes,sha256:r.sha256,format:r.format == "png" ? .png : .jpeg)
            }
            photoController.restore(loaded.record,unreadable:loaded.unreadableSave)
            status=loaded.result == nil ? (isLegacyCapture ? "历史作品已保留，本版仅提供竖向拼图" : "内容已保留，可以继续制作") : "上次的图片已恢复"
            if let set=loaded.captureSet {
                switch set.status {
                case .complete:status="长图已生成，共 \(set.pages.count) 张图片"
                case .staticFrame:status="录制中没有可确认的滚动，已保留完整单帧"
                case .separated:status="已保留全部 \(Set(set.pages.map(\.document)).count) 段内容，请逐段查看"
                case .noUsableContent:status="这次录制没有可用正文，原始素材仍已保留"
                case .recoverableFailure:status="整理尚未完成，素材和进度已保留"
                }
                if let elapsed=loaded.elapsed { metrics=String(format:"整理 %.2f 秒 · %d 张图片",elapsed,set.pages.count) }
            }
        case .editFailed(let snapshot,let error):
            if let snapshot { apply(.snapshot(snapshot)) } else { clearOutput() }
            report(error)
        case .snapshot(let snapshot):
            if self.snapshot.manifest?.taskID != snapshot.manifest?.taskID ||
                self.snapshot.edit?.revision != snapshot.edit?.revision ||
                self.snapshot.capture?.sequence != snapshot.capture?.sequence { clearOutput() }
            if self.snapshot.manifest?.taskID != snapshot.manifest?.taskID ||
                self.snapshot.capture?.frames.count != snapshot.capture?.frames.count {
                captureFirst=0;captureLast=max(0,(snapshot.capture?.frames.count ?? 1)-1)
                cropTop=0;cropBottom=0;cropLeft=0;cropRight=0;automaticallyPrepareCapture=true;capturePreview=nil;thumbnails=[:]
            }
            let currentIDs=Set(snapshot.edit?.assets.map(\.id) ?? snapshot.capture?.frames.map(\.id) ?? [])
            thumbnails=thumbnails.filter { currentIDs.contains($0.key) }
            self.snapshot = snapshot
            restoreCaptureSelection()
            status = snapshot.manifest == nil ? "选择一种方式开始" : "已读取当前任务"
            if let count = snapshot.edit?.unresolvedImports, count > 0 {
                status = "有 \(count) 张图片未能载入，请重新选择或移除。"
            }
            if snapshot.manifest != nil && self.result == nil && UIApplication.shared.applicationState == .active { restoreResult() }
        case .analysis(let result):
            if let edit=snapshot.edit {
                let plan:CompositionPlan?
                switch result.decision { case .ready(let value):plan=value;case .requiresConsent(_,_,let value):plan=value;case nil:plan=nil }
                if let plan,plan.taskID != edit.taskID || plan.revision != edit.revision { report(ScrollStitchError.staleOperation);return }
            }
            lastStage = "analysis"
            analysis = result.diagnostics
            switch result.decision {
            case .ready(let plan):
                proposal=plan; needsAdjustment=false; status="画面已整理完成"
                if let format=generationFormat { generationFormat=nil;render(format:format) }
            case .requiresConsent(let originalWidth, let originalHeight, let plan):
                downscale = plan; status = "原尺寸 \(originalWidth)×\(originalHeight) 超出预算，需要确认缩小。"
            case nil:
                generationFormat=nil;report(ScrollStitchError.invalidSelection)
            }
        case .rendered(let result):
            guard isCurrentResult(result.result) else { report(ScrollStitchError.staleOperation);return }
            lastStage = "render"; lastRenderSeconds = result.elapsed
            artifact = result.artifact; self.result=result.result; preview = UIImage(cgImage:result.preview)
            photoController.restore(result.photoRecord,unreadable:result.unreadableSave)
            metrics = String(format:"生成 %.2f 秒 · 文件 %.2f MiB\n进程生命周期最大 RSS %.1f MiB（不是单次峰值）", result.elapsed,
                Double(result.artifact.sizeBytes)/1_048_576, Double(result.maximumResidentBytes)/1_048_576)
            status = "本地结果已生成并重新解码校验"
        case .cleared(let removed):
            clearOutput(); status = removed ? "本地任务已清理" : isLegacyCapture ? "素材仍被占用，尚未清除；请稍后再次清除。" : "任务仍被采集或处理占用，已登记延后清理。"
            refresh()
        }
    }
    func cancel() {
        generationFormat=nil
        cancellation?.cancel()
        // Keep busy until the worker has exited: a new task cannot race an old commit.
        status = "正在取消；已写入的素材会保留，未完成项仍需处理。"
    }
    func handleMemoryWarning() {
        cancellation?.cancel(reason:.memoryPressure)
        capturePreview=nil; preview=nil; thumbnails=[:];collagePreview=nil;collagePreviewAssetID=nil
        // Keep busy until the existing worker exits; do not race a new commit or clear the task.
        status = busy ? "系统内存紧张，正在停止处理；已提交素材会保留。" : "系统内存紧张，已释放预览。原始素材已保留。"
    }
    func refresh() {
        guard let store, !operationLocked else { return }
        launch("读取本地任务…") { _ in .snapshot(try Self.read(store)) }
    }
    private func restoreCaptureSelection() {
        guard let capture=snapshot.capture,let size=capture.frames.first?.asset.size,
              let saved=UserDefaults.standard.dictionary(forKey:selectionKey),
              saved["task"] as? String == capture.taskID.uuidString,saved["count"] as? Int == capture.frames.count,
              let first=saved["first"] as? Int,let last=saved["last"] as? Int,
              let top=saved["top"] as? Int,let bottom=saved["bottom"] as? Int,
              let left=saved["left"] as? Int,let right=saved["right"] as? Int,
              first>=0,last>=first,last<capture.frames.count,[top,bottom,left,right].allSatisfy({$0>=0}),
              top<=size.height-64,bottom<=size.height-64-top,left<=size.width-24,right<=size.width-24-left else { return }
        captureFirst=first;captureLast=last;cropTop=top;cropBottom=bottom;cropLeft=left;cropRight=right
        automaticallyPrepareCapture=saved["automatic"] as? Bool ?? true
    }
    func importImages(_ inputs: [PickerInput], request: CollagePickerRequest) {
        guard let store, !inputs.isEmpty, !operationLocked else { return }
        let taskID=request.taskID, revision=request.revision, replacing=request.replacing, interactionAt=Date()
        launch("正在添加图片…") { cancellation in
            do {
                _ = try await PickerBatchLoader.ingest(inputs,store:store,interactionAt:interactionAt,cancellation:cancellation,
                                                       taskID:taskID,expectedRevision:revision,replacing:replacing)
                return .snapshot(try Self.read(store))
            } catch {
                // A batch may have committed some slots before storage failed. Read back
                // authoritative state before exposing any previously generated result.
                return Self.failedEdit(store,error:error)
            }
        }
    }
    nonisolated private static func failedEdit(_ store:TaskStore,error:any Error)->PrototypeResult {
        .editFailed(try? Self.read(store),(error as? ScrollStitchError) ?? .storageFailure)
    }
    private func applyCollageEdit(_ command: EditCommand) {
        guard let store, let edit=snapshot.edit, canEdit else { return }
        launch("正在保存修改…") { _ in
            do {
                _=try store.applyEdit(taskID:edit.taskID,expectedRevision:edit.revision,command:command)
                return .snapshot(try Self.read(store))
            } catch { return Self.failedEdit(store,error:error) }
        }
    }
    func removeImport(_ id: UUID) { applyCollageEdit(.remove(id)) }
    func reorderImports(_ ids: [UUID]) { applyCollageEdit(.reorder(ids)) }
    func moveImport(_ id: UUID, offset: Int) {
        guard let edit=snapshot.edit, let index=edit.orderedImports.firstIndex(where:{$0.id==id}),
              edit.orderedImports.indices.contains(index+offset) else { return }
        var ids=edit.orderedImports.map(\.id); ids.swapAt(index,index+offset); reorderImports(ids)
    }
    func setCollageCrop(_ assetID: UUID, rect: CropRect?) { applyCollageEdit(.crop(assetID,rect)) }
    func undoCollageEdit() {
        guard let store,let edit=snapshot.edit,edit.undo != nil,canEdit else { return }
        launch("正在撤销…") { _ in
            do {
                _=try store.undoEdit(taskID:edit.taskID,expectedRevision:edit.revision)
                return .snapshot(try Self.read(store))
            } catch { return Self.failedEdit(store,error:error) }
        }
    }
    func loadCollagePreview(_ asset: SourceAsset) {
        guard let store,let task=snapshot.edit,task.assets.contains(asset),!operationLocked else { return }
        if collagePreviewAssetID==asset.id,collagePreview != nil { return }
        collagePreview=nil;collagePreviewAssetID=nil
        launch("正在打开图片…") { flag in
            let lease=try store.acquireShareLease(taskID:task.taskID)
            defer { withExtendedLifetime(lease) {} }
            let image=try ImageDecoder.normalized(store.assetURL(asset,taskID:task.taskID),maxDimension:1200)
            try flag.check()
            return .collagePreview(image,asset.id)
        }
    }
    func loadThumbnails() {
        guard canEdit, let store, let task=snapshot.manifest else { return }
        let assets=snapshot.capture?.frames.map(\.asset) ?? snapshot.edit?.assets ?? []
        guard !assets.isEmpty, !assets.allSatisfy({thumbnails[$0.id] != nil}) else { return }
        launch("正在准备画面…") { flag in
            let lease=try store.acquireShareLease(taskID:task.taskID)
            defer { withExtendedLifetime(lease) {} }
            var images:[UUID:CGImage]=[:]
            for asset in assets {
                try flag.check()
                images[asset.id]=try autoreleasepool { try ImageDecoder.normalized(store.assetURL(asset,taskID:task.taskID),maxDimension:240) }
            }
            return .thumbnails(ThumbnailResult(images:images))
        }
    }
    func prepareEditor() {
        guard canEdit else { return }
        preview=nil
        loadThumbnails()
    }
    func generate(format:ImageFormat) {
        guard canEdit,snapshot.manifest?.kind == .collage else {return}
        generationFormat=format;needsAdjustment=false;analyze()
    }
    func applyExportFormat(_ format:ImageFormat) {generate(format:format)}
    func showCapturePage(_ index:Int) {
        guard let store,let set=captureResultSet,!operationLocked,set.pages.indices.contains(index) else { return }
        let fingerprint=selectionFingerprint
        launch("正在读取第 \(index+1) 张图片…") { flag in
            let loaded=try Self.loadCaptureResult(store:store,taskID:set.taskID,fingerprint:fingerprint,page:index)
            try flag.check();return .restored(loaded)
        }
    }
    nonisolated private static func loadCaptureResult(store:TaskStore,taskID:UUID,fingerprint:String,page:Int) throws -> RestoredResult {
        guard let set=try store.captureResultSet(taskID:taskID,selectionFingerprint:fingerprint) else { throw ScrollStitchError.staleOperation }
        guard !set.pages.isEmpty else { return RestoredResult(captureSet:set,result:nil,image:nil,record:nil,unreadableSave:false) }
        guard set.pages.indices.contains(page) else { throw ScrollStitchError.invalidSelection }
        let descriptor=set.pages[page].result
        let access=try store.openResult(taskID:taskID,resultID:descriptor.id)
        let image=try ImageDecoder.normalized(access.url,maxDimension:4096)
        var record:PhotoSaveRecord?,unreadable=false
        do { record=try store.photoSaveRecord(access) } catch { unreadable=true }
        return RestoredResult(captureSet:set,pageIndex:page,result:descriptor,image:image,record:record,unreadableSave:unreadable)
    }
    func confirmDownscale(format: ImageFormat) {
        guard canEdit,let plan=downscale else { return }
        proposal=plan;downscale=nil;generationFormat=nil;render(format:format)
    }
    func declineDownscale() { downscale=nil;generationFormat=nil }
    func setOptions(spacing: Int? = nil, background: CanvasBackground? = nil, width: WidthMode? = nil) {
        applyCollageEdit(.options(spacing:spacing,background:background,width:width))
    }
    func analyze() {
        guard canEdit,let store,let task=snapshot.edit else {return}
        clearOutput()
        launch("正在排版图片…") {flag in
            try flag.check();try store.recordInteraction(taskID:task.taskID)
            let edit=try store.editSnapshot(taskID:task.taskID)
            guard edit.unresolvedImports==0 else {throw ScrollStitchError.invalidSelection}
            let decision=try LayoutEngine.propose(taskID:edit.taskID,revision:edit.revision,
                inputs:try LayoutEngine.inputs(for:edit),kind:.collage,widthMode:edit.widthMode,
                spacingPx:edit.spacingPx,background:edit.background)
            return .analysis(AnalysisResult(decision:decision,diagnostics:"已按选择顺序排版"))
        }
    }
    func acceptDownscale() { guard canEdit else { return }; proposal = downscale; downscale = nil; status = "已确认缩小，可生成完整预览" }
    func render(format: ImageFormat) {
        guard canEdit, let store, let plan = proposal else { return }
        preview=nil; capturePreview=nil; artifact=nil
        let fingerprint=selectionFingerprint
        launch("正在生成图片…") { flag in
            try store.recordInteraction(taskID:plan.taskID)
            let start = ProcessInfo.processInfo.systemUptime
            let artifact = try ImageRenderer.render(plan,store:store,format:format,cancelled: { flag.isCancelled })
            let descriptor=try Self.resultDescriptor(artifact,fingerprint:fingerprint)
            try store.publishResult(descriptor)
            let access=try store.openResult(taskID:descriptor.taskID,resultID:descriptor.id)
            let thumbnail=try ImageDecoder.normalized(access.url,maxDimension:4096)
            var record:PhotoSaveRecord?, unreadable=false
            do { record=try store.photoSaveRecord(access) } catch { unreadable=true }
            try flag.check()
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            return .rendered(RenderResult(artifact:artifact,result:descriptor,photoRecord:record,unreadableSave:unreadable,preview:thumbnail,
                elapsed:ProcessInfo.processInfo.systemUptime-start,maximumResidentBytes:Int(usage.ru_maxrss)))
        }
    }
    private func isCurrentResult(_ descriptor: ResultManifest) -> Bool {
        descriptor.taskID==snapshot.manifest?.taskID &&
        descriptor.revision==(snapshot.edit?.revision ?? snapshot.capture?.sequence) &&
        (descriptor.selectionFingerprint==selectionFingerprint ||
         (captureResultSet?.selectionFingerprint==selectionFingerprint && captureResultSet?.pages.contains(where:{$0.result.id==descriptor.id})==true))
    }
    var selectionFingerprint: String {
        let data = "\(snapshot.manifest?.taskID.uuidString ?? "none")|\(snapshot.edit?.revision ?? snapshot.capture?.sequence ?? 0)|\(captureFirst)|\(captureLast)|\(cropTop)|\(cropBottom)|\(cropLeft)|\(cropRight)" +
            (snapshot.capture != nil && !automaticallyPrepareCapture ? "|unprocessed":"")
        return TaskStore.digest(data:Data(data.utf8))
    }
    nonisolated private static func resultDescriptor(_ artifact: ExportArtifact, fingerprint: String) throws -> ResultManifest {
        try ResultManifest(taskID:artifact.taskID,revision:artifact.revision,selectionFingerprint:fingerprint,
            path:AssetPath("exports/"+artifact.url.lastPathComponent),format:artifact.format.rawValue,
            size:artifact.size,sizeBytes:artifact.sizeBytes,sha256:artifact.sha256)
    }
    func restoreResult() {
        guard let store, let task=snapshot.manifest, !operationLocked else { return }
        let fingerprint=selectionFingerprint
        capturePreview=nil
        launch("正在恢复作品…") { flag in
            if task.kind == .capture,try store.captureResultSet(taskID:task.taskID,selectionFingerprint:fingerprint) != nil {
                return .restored(try Self.loadCaptureResult(store:store,taskID:task.taskID,fingerprint:fingerprint,page:0))
            }
            guard let descriptor=try store.currentResult(taskID:task.taskID,selectionFingerprint:fingerprint) else {
                return .restored(RestoredResult(result:nil,image:nil,record:nil,unreadableSave:false))
            }
            let access=try store.openResult(taskID:task.taskID,resultID:descriptor.id)
            let image=try ImageDecoder.normalized(access.url,maxDimension:4096)
            try flag.check()
            var record:PhotoSaveRecord?, unreadable=false
            do { record=try store.photoSaveRecord(access) } catch { unreadable=true }
            return .restored(RestoredResult(result:descriptor,image:image,record:record,unreadableSave:unreadable))
        }
    }
    func saveToPhotos(confirmedRepeat: Bool = false) {
        guard let store, let result, !operationLocked else { return }
        preparingExport=true
        Task { [weak self] in
            guard let self else { return }
            self.preparingExport=false
            await self.photoController.save(store:store,result:result,confirmedRepeat:confirmedRepeat)
        }
    }
    func stopSavingPages() { cancelPageSave=true;status="将在当前图片保存结束后停止" }
    func saveAllPages() {
        guard let store,let set=captureResultSet,!set.pages.isEmpty,!operationLocked else { return }
        savingAllPages=true;preparingExport=true;cancelPageSave=false
        Task { [weak self] in
            guard let self else { return }
            let count=await self.photoController.saveAll(store:store,results:set.pages.map(\.result),
                cancelled:{self.cancelPageSave},progress:{done,total in self.status="正在保存 \(done) / \(total) 张"})
            let stoppedState=self.photoController.state
            let message=count==set.pages.count ? "全部 \(count) 张图片已保存到相册" :
                (stoppedState == .unknown ? "已确认保存 \(count) 张，下一张的相册写入结果待确认，请先检查相册" : "已确认保存 \(count) / \(set.pages.count) 张；其余图片仍在本机")
            let page=count<set.pages.count ? count:self.capturePageIndex
            let fingerprint=self.selectionFingerprint
            do {
                let loaded=try await Task.detached {
                    try Self.loadCaptureResult(store:store,taskID:set.taskID,fingerprint:fingerprint,page:page)
                }.value
                self.apply(.restored(loaded))
                if stoppedState == .denied || stoppedState == .restricted {self.photoState=stoppedState}
            } catch { self.photoController.restore(nil,unreadable:true) }
            self.preparingExport=false;self.savingAllPages=false
            self.status=message;self.shareFeedback=message
        }
    }
    func shareImage(allPages:Bool = false) {
        guard let store, let result, !operationLocked else { return }
        let ids=allPages ? (captureResultSet?.pages.map{$0.result.id} ?? [result.id]):[result.id]
        preparingExport=true; errorMessage=nil;shareFeedback=nil
        Task { [weak self] in
            let access=await Task.detached { () -> Result<[ResultAccess],any Error> in
                do {
                    try store.recordInteraction(taskID:result.taskID)
                    return .success(try store.openResults(taskID:result.taskID,resultIDs:ids))
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.preparingExport=false
            switch access {
            case .success(let value): self.imageShare=ImageShareSession(accesses:value)
            case .failure(let error): self.report(error)
            }
        }
    }
    func finishImageShare(completed: Bool, failed: Bool) {
        imageShare=nil
        status=failed ? "未能分享，图片仍保留，可以重新选择分享方式" : completed ? "图片已交给所选应用" : "图片已保留，可继续查看或保存"
        shareFeedback=status
    }
    func clearTask() {
        guard let store, let task = snapshot.manifest, !operationLocked else { return }
        launch("清理当前任务…") { _ in .cleared(try store.cleanup(taskID:task.taskID,explicit:true)) }
    }
    func runRequestedInputDiagnosticIfReady() {
        guard BuildMode.operatorToolsEnabled else { return }
        guard !launchDiagnosticConsumed, !busy, storeReady, UIApplication.shared.applicationState == .active,
              ProcessInfo.processInfo.arguments.contains("--m0-local-input-diagnostic") else { return }
        launchDiagnosticConsumed=true
        runInputDiagnostics(requireOffline:false)
    }
    func runInputDiagnostics(requireOffline: Bool = true) {
        guard BuildMode.operatorToolsEnabled else { return }
        guard let store, !operationLocked else { return }
        inputDiagnosticSummary=""
        let revision=Bundle.main.object(forInfoDictionaryKey:"M0BuildRevision") as? String ?? "unbound"
        measuring=true;previousIdleTimerSetting=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        launch(requireOffline ? "检查离线状态，运行自制输入异常与恢复诊断…" : "运行本机输入异常与恢复诊断；本次不验证离线条件…") { flag in
            .inputDiagnostic(try await InputDiagnostics.run(store:store,cancellation:flag,buildRevision:revision,requireOffline:requireOffline))
        }
    }
    func suspendMeasurements() {
        if busy {
            generationFormat=nil
            cancellation?.cancel(reason:.background)
            status="正在暂停处理，原始素材会保留…"
        }
    }
    func exportDiagnostics() {
        guard let store, let task = snapshot.manifest, !operationLocked else { return }
        let stage = lastStage, errorCode = lastErrorCode, elapsed = lastRenderSeconds
        launch("准备本地诊断文件…") { flag in
            try flag.check()
            try store.recordInteraction(taskID:task.taskID)
            return .diagnostic(try DiagnosticExport.create(store:store,taskID:task.taskID,lastStage:stage,errorCode:errorCode,renderSeconds:elapsed))
        }
    }
    private func report(_ error: any Error) {
        generationFormat=nil
        lastErrorCode = (error as? ScrollStitchError).map { String(describing:$0) } ?? "system_error"
        if let processing=error as? CaptureProcessingError {
            let message:String
            switch processing {
            case .deadline:message="本轮整理已暂停，素材和进度已保留。点“生成”可继续。"
            case .invalid:message="本次整理未完成，原始素材和已有作品仍在，请继续整理或查看已保留的部分。"
            }
            status=message;errorMessage=message;return
        }
        let message: String
        switch error as? ScrollStitchError {
        case .cancelled: message = "操作已取消，原始素材已保留。"
        case .captureActive: message = "仍在录屏，请先从系统录屏入口停止，再回到卷轴。"
        case .existingTask: message = "请先完成当前作品，再开始新的制作。"
        case .invalidSelection: message = "请选择 2–20 张有效图片，并处理全部未完成项。"
        case .budgetExceeded: message = "图片过大，请选择更短的内容范围或减少图片后重试。"
        case .unresolvedSeams: message = "部分画面还不能连接，请调整内容范围后重试。"
        case .revisionConflict, .staleOperation, .wrongTask: message = "内容已经变化，请重新打开当前作品后重试。"
        default: message = "暂时无法完成，原始素材已保留。请稍后再试。"
        }
        status = message; errorMessage = message
    }
}
