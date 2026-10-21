import SwiftUI

private enum CollagePage:Hashable {case editor,result,help}
struct CollageWorkspaceView:View {
    @StateObject private var model=PrototypeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var path:[CollagePage]=[]
    @State private var picker:CollagePickerRequest?
    @State private var cropping:SourceAsset?
    @State private var confirmClear=false
    @State private var confirmRepeat=false
    @State private var downscalePrompt=false
    @State private var outputOptions=false
    @State private var openGenerated=false
    @State private var format=ImageFormat.jpeg
    @State private var zoomCommand=0
    private var isCollage:Bool {model.snapshot.manifest?.kind == .collage}
    var body:some View {
        NavigationStack(path:$path) {
            home.navigationTitle("多图拼接").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.topBarTrailing) {Button("帮助") {path.append(.help)}}}
                .navigationDestination(for:CollagePage.self) {page in
                    switch page {case .editor:editor;case .result:resultPage;case .help:help}
                }
        }
        .sheet(item:$picker) {request in
            OrderedImagePicker(selectionLimit:request.limit) {inputs in
                picker=nil;if !inputs.isEmpty {model.importImages(inputs,request:request)}
            }
        }
        .sheet(item:$cropping,onDismiss:{model.collagePreview=nil;model.collagePreviewAssetID=nil}) {asset in
            CollageCropEditor(model:model,asset:asset)
        }
        .sheet(item:$model.imageShare) {session in
            ImageShareActivity(session:session) {completed,failed in model.finishImageShare(completed:completed,failed:failed)}
        }
        .sheet(item:$model.diagnostic) {DiagnosticActivity(export:$0)}
        .sheet(isPresented:$outputOptions) {optionsSheet}
        .alert("暂时无法完成",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})) {
            Button("知道了",role:.cancel) {model.errorMessage=nil}
        } message:{Text(model.errorMessage ?? "")}
        .alert("清除本次素材？",isPresented:$confirmClear) {
            Button("继续保留",role:.cancel) {}
            Button("清除本次素材",role:.destructive) {model.clearTask()}
        } message:{Text("本次素材和本地预览将被清除。已保存到相册的图片不会删除。")}
        .alert("需要缩小后生成",isPresented:$downscalePrompt) {
            Button("返回调整",role:.cancel) {openGenerated=false;model.declineDownscale()}
            Button("缩小并生成") {openGenerated=true;model.confirmDownscale(format:format)}
        } message:{if let plan=model.downscale {Text("将生成 \(plan.size.width) × \(plan.size.height) 像素的图片。原始素材会保留。")}}
        .onChange(of:scenePhase) {_,phase in if phase == .active {model.refresh()} else {model.suspendMeasurements()}}
        .onChange(of:model.downscale != nil) {_,value in if value {downscalePrompt=true}}
        .onChange(of:model.busy) {_,busy in
            if !busy,path.last == .editor,model.canEdit {model.loadThumbnails()}
        }
        .onChange(of:model.result?.id) {_,id in
            if id != nil,openGenerated {openGenerated=false;if path.last != .result {path.append(.result)}}
        }
        .onChange(of:model.snapshot.manifest?.taskID) {old,new in
            if new == nil {path=[]}
            else if old == nil,isCollage {path=[.editor]}
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) {_ in model.handleMemoryWarning()}
    }
    private var home:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("把图片拼在一起").font(.largeTitle.bold())
                Text("选择 2–20 张图片，调整顺序、裁剪和间距。").foregroundStyle(.secondary)
                if model.snapshot.manifest != nil {
                    VStack(alignment:.leading,spacing:16) {
                        Label(isCollage ? "上次的拼图":"历史录屏作品已保留",systemImage:"doc.richtext").font(.headline)
                        if model.result != nil {
                            Button("查看作品") {path.append(.result)}.buttonStyle(PrimaryActionStyle())
                        }
                        if isCollage {
                            Button("继续制作") {path.append(.editor)}.buttonStyle(PrimaryActionStyle(secondary:true))
                        } else {
                            Text("原始素材和已有结果继续保留。新滚动截图从控制中心开始。").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("清除本次素材",role:.destructive) {confirmClear=true}.disabled(model.operationLocked)
                    }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:22))
                } else {
                    Button("选择图片") {picker=CollagePickerRequest()}.buttonStyle(PrimaryActionStyle()).disabled(!model.storeReady || model.operationLocked)
                }
                if model.busy {processingProgress}
                Text("图片在本机处理").font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }.background(Color(uiColor:.systemGroupedBackground))
    }
    private var processingProgress:some View {
        HStack {ProgressView();Text(model.status);Spacer();Button("取消") {openGenerated=false;model.cancel()}}.padding()
    }
    private var editor:some View {
        CollageEditorList(model:model,add:{openCollagePicker()},retry:{openCollagePicker(replacing:$0)},crop:{cropping=$0})
            .navigationTitle("调整拼图").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge:.bottom) {
                VStack {
                    if model.busy {processingProgress}
                    Button("生成拼图") {openGenerated=true;model.generate(format:format)}.buttonStyle(PrimaryActionStyle())
                        .disabled(!model.canEdit || (model.snapshot.edit?.assets.count ?? 0)<2 || (model.snapshot.edit?.unresolvedImports ?? 0)>0)
                }.padding().background(.bar)
            }.onAppear {model.prepareEditor()}
    }
    private func openCollagePicker(replacing:UUID? = nil) {
        guard model.canEdit,let edit=model.snapshot.edit else {return}
        let limit=replacing == nil ? 20-edit.orderedImports.count:1
        if limit>0 {picker=CollagePickerRequest(taskID:edit.taskID,revision:edit.revision,replacing:replacing,limit:limit)}
    }
    private var help:some View {
        List {
            Section("使用方法") {
                Text("选择图片后调整顺序、裁剪、间距和背景，再生成并保存拼图。")
                Text("未保存作品保留在本机。清除素材需再次确认。")
            }
            Section {NavigationLink("隐私与数据") {ProductInformationView()};LabeledContent("版本",value:ProductInformationView.versionLabel)}
            if model.snapshot.manifest != nil {Section {Button("导出诊断信息") {model.exportDiagnostics()}.disabled(model.operationLocked)}}
        }.navigationTitle("帮助")
    }
    private var resultPage:some View {
        VStack(spacing:0) {
            if let set=model.captureResultSet,set.pages.count>1 {
                HStack {
                    Button { model.showCapturePage(model.capturePageIndex-1) } label:{Image(systemName:"chevron.left").frame(width:44,height:44)}
                        .accessibilityLabel("上一张").disabled(model.operationLocked || model.capturePageIndex==0)
                    Spacer()
                    Text("第 \(model.capturePageIndex+1) / \(set.pages.count) 张").monospacedDigit()
                    Spacer()
                    Button { model.showCapturePage(model.capturePageIndex+1) } label:{Image(systemName:"chevron.right").frame(width:44,height:44)}
                        .accessibilityLabel("下一张").disabled(model.operationLocked || model.capturePageIndex+1==set.pages.count)
                }.padding(.horizontal,16)
            }
            if let note=model.result?.completenessNote {
                Label(note,systemImage:"exclamationmark.circle").font(.subheadline)
                    .foregroundStyle(.orange).padding(16).frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack {
                if let result=model.result { Text("\(result.format.uppercased()) · \(result.size.width) × \(result.size.height)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !model.isLegacyCapture { Button("导出选项") { outputOptions=true }.font(.subheadline).frame(minHeight:44).disabled(model.operationLocked) }
            }.padding(.horizontal,20)
            if let preview=model.preview {
                ZoomableResult(image:preview,zoomCommand:zoomCommand).overlay(alignment:.topTrailing) {
                    HStack(spacing:0) {
                        Button { zoomCommand-=1 } label:{Image(systemName:"minus.magnifyingglass").frame(width:44,height:44)}.accessibilityLabel("缩小预览")
                        Button { zoomCommand+=1 } label:{Image(systemName:"plus.magnifyingglass").frame(width:44,height:44)}.accessibilityLabel("放大预览")
                    }.background(.regularMaterial,in:Capsule()).padding(12)
                }
            } else {
                ContentUnavailableView { Label("图片已保留",systemImage:"photo") } description:{Text("点下方按钮重新载入预览，也可以直接保存或分享。")} actions:{Button("载入预览") { model.restoreResult() }.disabled(model.operationLocked)}
            }
        }
        .background(Color(uiColor:.systemGroupedBackground))
        .navigationTitle(model.result?.completenessNote != nil ? "已完成的部分" : (isCollage ? "拼图预览" : "历史作品")).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) {
                Button {
                    if model.isLegacyCapture { path=[] }
                    else if path.contains(.editor) { path.removeLast() } else { path=[.editor] }
                } label: {
                    Text(model.isLegacyCapture ? "首页" : "调整").fixedSize()
                }.accessibilityLabel(model.isLegacyCapture ? "返回首页" : "调整作品").disabled(model.operationLocked)
            }
            ToolbarItem(placement:.topBarTrailing) {
                Menu {
                    Button("回到首页",systemImage:"house") { path=[] }
                    if (model.captureResultSet?.pages.count ?? 0)>1 {
                        Button("分享全部图片",systemImage:"square.and.arrow.up.on.square") { model.shareImage(allPages:true) }
                    }
                    if model.photoState == .saved { Button("再保存一份",systemImage:"square.and.arrow.down") { confirmRepeat=true } }
                    Button("完成并清除本次素材",systemImage:"trash",role:.destructive) { confirmClear=true }
                } label:{Image(systemName:"ellipsis").frame(width:44,height:44)}.accessibilityLabel("作品选项").disabled(model.operationLocked)
            }
        }
        .safeAreaInset(edge:.bottom) { exportBar }
        .alert(model.photoState == .unknown ? "先确认相册中是否已有图片" : "再保存一份？",isPresented:$confirmRepeat) {
            Button("取消",role:.cancel) {}
            Button(model.photoState == .unknown ? "已检查，仍要保存" : "确认再存一份") { model.saveToPhotos(confirmedRepeat:true) }
        } message:{Text("此操作会向相册添加一张图片。如果上次已经保存成功，相册会出现重复图片。")}
        .onAppear { if model.preview == nil { model.restoreResult() } }
    }
    private var exportBar:some View {
        VStack(spacing:12) {
            if model.photoState == .denied || model.photoState == .restricted {
                HStack(alignment:.top) {
                    Text(model.photoState == .restricted ? "系统限制了添加照片，仍可通过分享导出。" : "尚未允许添加照片，仍可使用分享。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength:4)
                    if model.photoState == .denied { Button("去设置") { if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.footnote) }
                }
            } else if model.photoState == .unknown {
                Text("上次保存结果待确认，请先查看相册。卷轴不会自动重复保存。").font(.footnote).foregroundStyle(.secondary)
            } else if model.photoState == .failed { Text("没有完成保存，图片仍在这里，可以重试或分享。").font(.footnote).foregroundStyle(.secondary) }
            HStack(spacing:12) {
                Button {
                    if model.photoState == .unknown { confirmRepeat=true } else { model.saveToPhotos() }
                } label: {
                    HStack { if model.photoState.isBusy { ProgressView().tint(.white) } else { Image(systemName:model.photoState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down") };Text(saveLabel) }
                }.buttonStyle(PrimaryActionStyle()).disabled(model.operationLocked || model.result == nil || model.photoState == .saved)
                Button { model.shareImage() } label:{Label("分享",systemImage:"square.and.arrow.up")}
                    .buttonStyle(PrimaryActionStyle(secondary:true)).frame(maxWidth:125).disabled(model.operationLocked || model.result == nil)
            }
            if (model.captureResultSet?.pages.count ?? 0)>1 {
                if model.savingAllPages { Button("停止保存剩余图片") { model.stopSavingPages() } }
                else { Button("保存全部图片到相册") { model.saveAllPages() }.disabled(model.operationLocked) }
            }
            Text(model.shareFeedback ?? (model.photoState == .saved ? "已保存到相册" :
                (model.result?.completenessNote != nil ? "各段之间仍有缺口，当前保存和分享的是这一张" : (model.captureResultSet?.pages.count ?? 0)>1 ? "逐张查看并保存，也可在右上角分享全部图片" : "确认内容完整后，保存这张图片")))
                .font(.caption).foregroundStyle(model.photoState == .saved ? Color.green : Color.secondary)
        }.padding(.horizontal,20).padding(.vertical,14).background(.bar)
    }
    private var saveLabel:String {
        switch model.photoState {
        case .authorizing:return "等待授权…"
        case .writing:return "正在保存…"
        case .saved:return "已保存"
        case .unknown:return "检查后再保存"
        case .failed:return "重试保存"
        default:return model.result?.completenessNote != nil ? "保存已完成部分" : "保存到相册"
        }
    }
    private var optionsSheet:some View {
        NavigationStack {
            Form {
                Section("图片格式") {
                    Picker("格式",selection:$format) { Text("PNG · 文字更清晰").tag(ImageFormat.png);Text("JPEG · 适合照片").tag(ImageFormat.jpeg) }
                        .pickerStyle(.inline).labelsHidden()
                }
                if let result=model.result {
                    Section("当前图片") { LabeledContent("尺寸",value:"\(result.size.width) × \(result.size.height) 像素");LabeledContent("文件大小",value:ByteCountFormatter.string(fromByteCount:Int64(result.sizeBytes),countStyle:.file)) }
                }
                if !model.isLegacyCapture { Section { Button("应用并生成") { outputOptions=false;openGenerated=true;model.applyExportFormat(format) }.disabled(!model.canEdit) } }
            }.navigationTitle("导出选项").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { outputOptions=false } } }
        }.presentationDetents([.medium,.large])
    }
}
