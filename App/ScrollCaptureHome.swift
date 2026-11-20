#if canImport(ScreenCaptureKit)
import SwiftUI
import UserNotifications

struct ScrollCaptureHome:View {
    @ObservedObject private var capture=ScrollCaptureCoordinator.shared
    @AppStorage("scroll.onboarding.completed") private var introduced=false
    @State private var guide=false
    @Environment(\.scenePhase) private var scenePhase
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    VStack(alignment:.leading,spacing:10) {
                        Text("滚过的内容\n一张留下").font(.system(size:36,weight:.bold))
                        Text("控制中心开始，灵动岛完成。\n卷轴自动整理并保存到照片。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical,12)
                    if capture.active {
                        VStack(alignment:.leading,spacing:16) {
                            Label(capture.message,systemImage:"record.circle").font(.headline)
                            if capture.session?.phase == .recording || capture.session?.phase == .paused {
                                HStack {
                                    Button(capture.session?.phase == .paused ? "继续":"接下一页") {Task {await capture.nextPage()}}
                                    Spacer()
                                    Button("完成") {Task {await capture.finish()}}
                                }.buttonStyle(.borderedProminent)
                            } else {ProgressView()}
                        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:24))
                    }
                    VStack(alignment:.leading,spacing:16) {
                        Text("拼接方向").font(.headline)
                        Picker("拼接方向",selection:$capture.axis) {
                            Text("纵向 ↕️").tag(ScrollAxis.vertical)
                            Text("横向 ↔️").tag(ScrollAxis.horizontal)
                        }.pickerStyle(.segmented).disabled(capture.active)
                        Text("同一页沿一个方向轴滚动，可往返查看。").font(.footnote).foregroundStyle(.secondary)
                        Toggle("保留状态栏", isOn: $capture.keepsStatusBar).disabled(capture.active)
                        Text("方向与状态栏设置仅用于下一次截图。").font(.caption).foregroundStyle(.secondary)
                        if !capture.active {
                            Button("开始滚动截图", systemImage: "record.circle") { Task { await capture.toggle() } }
                                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
                            Text("也可以直接在目标 App 的控制中心开始。").font(.footnote).foregroundStyle(.secondary)
                        } else if capture.session?.phase == .choosing {
                            Button("重新打开共享面板") { Task { await capture.toggle() } }
                        }
                        Button("查看使用方法",systemImage:"slider.horizontal.3") {guide=true}
                            .frame(maxWidth:.infinity,minHeight:44)
                    }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:24))
                    if let message=capture.errorMessage {
                        Label(message,systemImage:"exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if capture.session?.phase == .saved, capture.errorMessage == nil {
                        Label("长图已保存，请在「照片」中查看", systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                    if !capture.active, !capture.pendingCaptures.isEmpty {
                        Text("待处理截图").font(.headline)
                        ForEach(capture.pendingCaptures) { work in
                            recoveryRow(work)
                        }
                    }
                    Text("全部在本机处理 · 不录制声音").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth:.infinity).padding(.bottom,16)
                }.padding(24)
            }.background(Color(uiColor:.systemGroupedBackground))
                .navigationTitle("卷轴").navigationBarTitleDisplayMode(.inline)
                .appHelp()
                .sheet(isPresented:$guide) {ScrollOnboarding {introduced=true;guide=false}}
        }
        .tint(.blue)
        .task {await capture.recover();if !introduced {guide=true}}
        .onChange(of:scenePhase) {_,phase in if phase == .active {Task {await capture.recover()}}}
    }
    private func recoveryRow(_ work: ScrollSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(work.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            switch work.phase {
            case .permissionRequired:
                Text("需要添加照片权限，长图已保留。")
                Button("重试保存") { Task { await capture.retry(work) } }
            case .saveUncertain:
                Text("保存结果待确认，请先查看「照片」。卷轴会保留素材，避免重复写入。")
            default:
                Text(work.message ?? "处理未完成，原始素材已保留。")
                Button("重试自动处理") { Task { await capture.retry(work) } }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ScrollOnboarding:View {
    let finish:()->Void
    @State private var page=0
    @State private var permission:String?
    private let titles=["把卷轴放进控制中心","轻点卷轴，确认开始","滚动内容，轻点完成"]
    private let details=[
        "以后无论正在看聊天、购物内容还是网页，都能从控制中心开始。",
        "在当前页面确认 Apple 的整个屏幕共享，然后继续滚动。",
        "无需等待固定倒计时。完成后，卷轴自动整理并保存到照片。"
    ]
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        Text("第 \(page+1) 步").font(.subheadline).foregroundStyle(.secondary)
                        Text(titles[page]).font(.system(size:34,weight:.bold))
                        Text(details[page]).font(.title3).foregroundStyle(.secondary)
                        illustration.padding(24).frame(maxWidth:.infinity,minHeight:180)
                            .background(.background,in:RoundedRectangle(cornerRadius:28))
                        VStack(alignment:.leading,spacing:22) {
                            if page==0 {
                                GuideStep(number:1,title:"打开控制中心",detail:"从屏幕右上角向下轻扫。")
                                GuideStep(number:2,title:"添加控制",detail:"长按空白处或轻点左上角“＋”，再点“添加控制”。")
                                GuideStep(number:3,title:"搜索卷轴",detail:"添加“卷轴”，也可以同时添加“卷轴 · 接下一页”。")
                            } else if page==1 {
                                GuideStep(number:1,title:"停在起点",detail:"先打开要截取的内容，停在想保留的起点。")
                                GuideStep(number:2,title:"轻点控制中心的卷轴",detail:"控制中心收起后，当前 App 保持不变。")
                                GuideStep(number:3,title:"确认共享整个屏幕",detail:"在 Apple 面板中轻点“共享整个屏幕”（Share Entire Screen）。")
                                GuideStep(number:4,title:"收起系统面板",detail:"共享开始后，轻点面板外的空白处收起提示，再沿设置的方向缓慢滚动；等待时停在原处。")
                            } else {
                                GuideStep(number:1,title:"同一方向轴，可往返滚动",detail:"纵向可上下往返，横向可左右往返。卷轴按内容顺序去重。")
                                GuideStep(number:2,title:"接下一页",detail:"长按灵动岛，点“接下一页”暂停；切换页面后点“继续”。独立的控制中心控件也能直接暂停或继续。")
                                GuideStep(number:3,title:"到终点，点完成",detail:"长按灵动岛后点“完成”，或再次点击控制中心的“卷轴”。")
                                GuideStep(number:4,title:"自动保存到照片",detail:"完成后打开系统「照片」查看长图。在其他 App 中接收完成提醒需要允许通知。")
                                Button("允许添加照片") {
                                    Task {let state=await PhotoKitWriter().requestAddOnly();permission=state == .authorized ? "已允许添加照片":"可在系统设置中允许添加照片"}
                                }.buttonStyle(.bordered)
                                Button("通知提醒设置") {
                                    Task {
                                        let allowed=(try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound])) ?? false
                                        permission=allowed ? "已允许完成提醒":"未开启提醒，仍可正常保存图片"
                                    }
                                }
                                if let permission {Text(permission).font(.footnote).foregroundStyle(.secondary)}
                            }
                        }.padding(24).background(.background,in:RoundedRectangle(cornerRadius:28))
                    }.padding(24)
                }
                VStack(spacing:18) {
                    HStack(spacing:8) {
                        ForEach(0..<3) {index in Capsule().fill(index==page ? Color.primary:Color.secondary.opacity(0.2)).frame(width:index==page ? 28:8,height:8)}
                    }
                    Button(page==2 ? "我会用了 ✓":"下一步 →") {
                        if page<2 {withAnimation {page+=1}}
                        else {Task {_ = await PhotoKitWriter().requestAddOnly();finish()}}
                    }.font(.title3.bold()).frame(maxWidth:.infinity,minHeight:64)
                        .foregroundStyle(Color(uiColor:.systemBackground)).background(Color.primary,in:RoundedRectangle(cornerRadius:22))
                }.padding(24).background(.bar)
            }.background(Color(uiColor:.systemGroupedBackground)).navigationTitle("卷轴").navigationBarTitleDisplayMode(.inline)
                .toolbar {ToolbarItem(placement:.topBarTrailing) {Button("关闭",action:finish)}}
        }
    }
    @ViewBuilder private var illustration:some View {
        if page==0 {
            VStack(spacing:24) {
                HStack {Image(systemName:"airplane");Spacer();Image(systemName:"wifi");Spacer();Image(systemName:"sun.max.fill")}.font(.title)
                Label("卷轴",systemImage:"viewfinder").font(.title.bold())
                Label("添加控制",systemImage:"plus").font(.headline)
            }
        } else if page==1 {
            VStack(spacing:20) {
                Text("开始屏幕录制").font(.headline)
                Label("Share Entire Screen",systemImage:"rectangle.on.rectangle").font(.title3.bold())
                Text("仅在设备上整理画面").foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing:24) {
                Label("完成",systemImage:"record.circle.fill").padding(.horizontal,24).padding(.vertical,12)
                    .foregroundStyle(.white).background(.black,in:Capsule())
                ForEach(0..<3) {_ in Capsule().fill(.secondary.opacity(0.15)).frame(height:12)}
                Image(systemName:"arrow.down").font(.largeTitle)
            }
        }
    }
}

#endif
