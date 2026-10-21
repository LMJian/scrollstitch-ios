import WidgetKit
import SwiftUI
import ActivityKit

@main struct ScrollWidgets: WidgetBundle {
    var body: some Widget {
        ScrollMainControl()
        ScrollNextPageControl()
        ScrollLiveActivity()
    }
}
struct ScrollMainControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind:ScrollControlState.mainKind, provider: ScrollControlProvider()) { phase in
            ControlWidgetButton(action:ToggleScrollIntent()) {
                Label(phase.title,systemImage:"viewfinder")
            }
        }
        .displayName("卷轴")
        .description("截取滚动内容，再次点击完成并自动保存。")
    }
}
struct ScrollNextPageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind:ScrollControlState.pageKind, provider: ScrollControlProvider()) { phase in
            ControlWidgetButton(action:NextScrollPageIntent()) {
                Label(phase == .paused ? "继续截图":"接下一页",systemImage:"rectangle.stack.badge.plus")
            }
            .disabled(phase != .recording && phase != .paused)
        }
        .displayName("卷轴 · 接下一页")
        .description("暂停换页，或继续录制。")
    }
}
struct ScrollControlProvider: ControlValueProvider {
    var previewValue: ScrollControlPhase { .idle }
    func currentValue() async throws -> ScrollControlPhase { ScrollControlState.current }
}
struct ScrollLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for:ScrollActivityAttributes.self) { context in
            VStack(alignment:.leading,spacing:12) {
                Label("卷轴",systemImage:"viewfinder").font(.headline)
                Text(context.state.message)
                actions(context.state)
            }.padding().activityBackgroundTint(Color.black).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName:"viewfinder").accessibilityLabel("卷轴") }
                DynamicIslandExpandedRegion(.trailing) { Text("第 \(context.state.page+1) 页") }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text("卷轴").font(.headline).lineLimit(1)
                        Text(context.state.message).font(.caption).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) { actions(context.state) }
            } compactLeading: {
                Image(systemName:"viewfinder").foregroundStyle(context.state.paused ? .orange:.red)
            } compactTrailing: {
                Text(context.state.paused ? "已暂停" : context.state.recording ? "录制中" : "整理中")
                    .font(.caption2)
            } minimal: { Image(systemName:"viewfinder") }
            .keylineTint(.white)
        }
    }
    @ViewBuilder private func actions(_ state:ScrollActivityAttributes.ContentState) -> some View {
        if state.recording || state.paused {
            HStack {
                Button(intent:NextScrollPageIntent()) {
                    Label(state.paused ? "继续":"接下一页",systemImage:state.paused ? "play.fill":"pause.fill")
                        .frame(maxWidth: .infinity).lineLimit(1)
                }.tint(.gray)
                Button(intent:FinishScrollIntent()) {
                    Label("完成",systemImage:"checkmark").frame(maxWidth: .infinity).lineLimit(1)
                }.tint(.red)
            }.buttonStyle(.borderedProminent)
        }
    }
}
