import SwiftUI

struct CollageEditorList: View {
    @ObservedObject var model: PrototypeModel
    let add: () -> Void
    let retry: (UUID) -> Void
    let crop: (SourceAsset) -> Void

    var body: some View {
        List {
            if let edit=model.snapshot.edit {
                Section {
                    ViewThatFits(in:.horizontal) {
                        HStack { addButton(edit); Spacer(); undoButton(edit) }
                        VStack(alignment:.leading) { addButton(edit); undoButton(edit) }
                    }
                    Text(edit.orderedImports.count>=20 ? "已选满 20 张，可移除后再添加。" : "长按图片右侧的排序柄拖动，也可以使用上移、下移。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if edit.orderedImports.count<2 { Text("再添加图片，至少 2 张就可以生成拼图。").font(.subheadline) }
                } header: { Text("图片 · \(edit.orderedImports.count)/20") }
                Section {
                    ForEach(Array(edit.orderedImports.enumerated()),id:\.element.id) { index,record in
                        row(record,index:index,total:edit.orderedImports.count)
                            .moveDisabled(!model.canEdit)
                    }
                    .onMove { indices,destination in
                        guard model.canEdit else { return }
                        var ids=edit.orderedImports.map(\.id)
                        ids.move(fromOffsets:indices,toOffset:destination)
                        model.reorderImports(ids)
                    }
                }
                Section("排版") {
                    Picker("间距",selection:Binding(get:{edit.spacingPx},set:{model.setOptions(spacing:$0)})) {
                        Text("无").tag(0);Text("小").tag(8);Text("中").tag(16);Text("大").tag(24)
                    }
                    Picker("背景",selection:Binding(get:{edit.background},set:{model.setOptions(background:$0)})) {
                        Text("白色").tag(CanvasBackground.white);Text("黑色").tag(CanvasBackground.black)
                    }
                    Picker("清晰度",selection:Binding(get:{edit.widthMode},set:{model.setOptions(width:$0)})) {
                        Text("标准").tag(WidthMode.standard);Text("更清晰").tag(WidthMode.original)
                    }
                }.disabled(!model.canEdit)
            }
        }
        .listStyle(.insetGrouped)
        // Native List owns drag autoscroll and only calls onMove on a committed drop.
        .environment(\.editMode,.constant(.active))
        .buttonStyle(.borderless)
    }
    private func addButton(_ edit: EditSnapshot) -> some View {
        Button(action:add) { Label("添加图片",systemImage:"plus") }.frame(minHeight:44)
            .disabled(!model.canEdit || edit.orderedImports.count>=20)
    }
    private func undoButton(_ edit: EditSnapshot) -> some View {
        Button(action:model.undoCollageEdit) { Label("撤销",systemImage:"arrow.uturn.backward") }
            .frame(minHeight:44).disabled(!model.canEdit || edit.undo == nil)
            .accessibilityHint(edit.undo.map { "撤销上次\($0.label)" } ?? "没有可撤销的操作")
    }
    private func row(_ record:ImportRecord,index:Int,total:Int) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                if let id=record.asset?.id,let image=model.thumbnails[id] {
                    Image(uiImage:image).resizable().scaledToFit().frame(width:58,height:70).accessibilityHidden(true)
                } else {
                    Image(systemName:record.asset == nil ? "exclamationmark.triangle":"photo")
                        .frame(width:58,height:70).accessibilityHidden(true)
                }
                VStack(alignment:.leading,spacing:5) {
                    Text("图片 \(index+1)").font(.headline)
                    if record.asset == nil {
                        Text(record.issue == .loading ? "正在载入…":"未能载入，重新选择或移除").font(.caption).foregroundStyle(.secondary)
                    } else if model.snapshot.edit?.crops.contains(where:{$0.assetID==record.asset?.id}) == true {
                        Text("已裁剪").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:16) { imageAction(record); moveButtons(record,index:index,total:total); removeButton(record,index:index) }
                VStack(alignment:.leading,spacing:0) {
                    HStack { imageAction(record); removeButton(record,index:index) }
                    moveButtons(record,index:index,total:total)
                }
            }
        }.padding(.vertical,6).disabled(!model.canEdit)
    }
    @ViewBuilder private func imageAction(_ record:ImportRecord) -> some View {
        if let asset=record.asset {
            Button("裁剪",systemImage:"crop") { crop(asset) }.frame(minHeight:44)
        } else { Button("重新选择") { retry(record.id) }.frame(minHeight:44) }
    }
    private func moveButtons(_ record:ImportRecord,index:Int,total:Int) -> some View {
        HStack(spacing:12) {
            Button("上移") { model.moveImport(record.id,offset:-1) }.disabled(index==0)
                .accessibilityLabel("上移图片 \(index+1)").frame(minHeight:44)
            Button("下移") { model.moveImport(record.id,offset:1) }.disabled(index==total-1)
                .accessibilityLabel("下移图片 \(index+1)").frame(minHeight:44)
        }
    }
    private func removeButton(_ record:ImportRecord,index:Int) -> some View {
        Button(role:.destructive) { model.removeImport(record.id) } label:{Image(systemName:"trash").frame(minWidth:44,minHeight:44)}
            .accessibilityLabel("移除图片 \(index+1)")
    }
}

struct CollageCropEditor: View {
    @ObservedObject var model: PrototypeModel
    let asset: SourceAsset
    private let taskID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CaptureInsets
    @State private var saving=false
    init(model:PrototypeModel,asset:SourceAsset) {
        self.model=model;self.asset=asset;self.taskID=model.snapshot.manifest?.taskID
        let rect=model.snapshot.edit?.crop(for:asset) ?? CropRect(width:asset.size.width,height:asset.size.height)
        _draft=State(initialValue:CaptureInsets(top:rect.y,bottom:asset.size.height-rect.y-rect.height,
                                               left:rect.x,right:asset.size.width-rect.x-rect.width))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("拖动蓝色边界，只保留想要的部分。原图不会改变。").font(.subheadline).foregroundStyle(.secondary)
                    if let image=model.collagePreview,model.collagePreviewAssetID==asset.id {
                        CropCanvas(image:image,size:asset.size,insets:draft,enabled:model.canEdit,collage:true) { edge,value in
                            draft=draft.adjustingForCollage(edge:edge,to:value,in:asset.size)
                        }.frame(height:440)
                    } else if model.busy { ProgressView("正在打开图片…").frame(maxWidth:.infinity,minHeight:300) }
                    else { Button("重新载入图片") { model.loadCollagePreview(asset) }.frame(maxWidth:.infinity,minHeight:300) }
                    Button("恢复原图范围") { draft=CaptureInsets() }.frame(minHeight:44).disabled(!model.canEdit)
                    DisclosureGroup("精细调整") {
                        cropSlider("上边界",edge:"top",value:draft.top,maximum:asset.size.height-draft.bottom-1)
                        cropSlider("下边界",edge:"bottom",value:draft.bottom,maximum:asset.size.height-draft.top-1)
                        cropSlider("左边界",edge:"left",value:draft.left,maximum:asset.size.width-draft.right-1)
                        cropSlider("右边界",edge:"right",value:draft.right,maximum:asset.size.width-draft.left-1)
                    }.disabled(!model.canEdit)
                    if let error=model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
                }.padding(22)
            }.background(Color(uiColor:.systemGroupedBackground))
                .navigationTitle("裁剪图片").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("完成") {
                            saving=true
                            model.setCollageCrop(asset.id,rect:CropRect(x:draft.left,y:draft.top,
                                width:asset.size.width-draft.left-draft.right,height:asset.size.height-draft.top-draft.bottom))
                        }.disabled(!model.canEdit || model.collagePreviewAssetID != asset.id || model.collagePreview == nil)
                    }
                }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { model.loadCollagePreview(asset) }
        .onChange(of:model.snapshot.manifest?.taskID) { _,id in if id != taskID { dismiss() } }
        .onChange(of:model.busy) { _,busy in
            guard !busy else { return }
            if saving { saving=false; if model.errorMessage == nil { dismiss() } }
            else if model.collagePreview == nil, model.errorMessage == nil { model.loadCollagePreview(asset) }
        }
    }
    private func cropSlider(_ title:String,edge:String,value:Int,maximum:Int) -> some View {
        VStack(alignment:.leading) {
            Text(title).font(.subheadline)
            Slider(value:Binding(get:{Double(value)},set:{draft=draft.adjustingForCollage(edge:edge,to:Int($0),in:asset.size)}),
                   in:0...Double(max(1,maximum)),step:1).disabled(maximum<=0)
                .accessibilityLabel(title).accessibilityValue("已去除 \(value) 像素")
        }
    }
}
