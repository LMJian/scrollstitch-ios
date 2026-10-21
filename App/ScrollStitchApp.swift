import SwiftUI

@main struct ScrollStitchApp:App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var fallbackTab = 0
#if !SCROLLSTITCH_COLLAGE_ONLY && canImport(ScreenCaptureKit)
    @UIApplicationDelegateAdaptor(ScrollAppDelegate.self) private var delegate
    @ObservedObject private var capture=ScrollCaptureCoordinator.shared
#endif
    init() {
#if !SCROLLSTITCH_COLLAGE_ONLY
        WorkdayAlarmBackground.register()
#endif
#if !SCROLLSTITCH_COLLAGE_ONLY && canImport(ScreenCaptureKit)
        ScrollBackground.register()
#endif
    }
    var body:some Scene {
        WindowGroup {
#if SCROLLSTITCH_COLLAGE_ONLY
            CollageWorkspaceView()
#elseif canImport(ScreenCaptureKit)
            TabView(selection:$capture.selectedTab) {
                ScrollCaptureHome().tabItem {Label("滚动截图",systemImage:"viewfinder")}.tag(0)
                CollageWorkspaceView().tabItem {Label("多图拼接",systemImage:"photo.on.rectangle.angled")}.tag(1)
                WorkdayAlarmHome(isActive: capture.selectedTab == 2).tabItem {Label("调休闹钟",systemImage:"alarm")}.tag(2)
            }
            .task {
                ScrollHostVisibility.shared.set(UIApplication.shared.applicationState == .active)
                await WorkdayAlarmService.shared.refreshExisting()
            }
            .onChange(of: scenePhase) { _, phase in
                // Inactive also means Control Center over another app. Preserve
                // the last actual scene state until active/background resolves.
                if phase == .active { ScrollHostVisibility.shared.set(true) }
                else if phase == .background { ScrollHostVisibility.shared.set(false) }
                if phase == .active { Task { await WorkdayAlarmService.shared.refreshExisting() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await WorkdayAlarmService.shared.refreshExisting() }
            }
#else
            TabView(selection: $fallbackTab) {
                ContentUnavailableView("请在真机使用滚动截图",systemImage:"iphone",
                    description:Text("模拟器不提供屏幕共享。请使用 iOS 27 或更高版本的 iPhone。"))
                    .tabItem {Label("滚动截图",systemImage:"viewfinder")}.tag(0)
                CollageWorkspaceView().tabItem {Label("多图拼接",systemImage:"photo.on.rectangle.angled")}.tag(1)
                WorkdayAlarmHome(isActive: fallbackTab == 2).tabItem {Label("调休闹钟",systemImage:"alarm")}.tag(2)
            }
            .task { await WorkdayAlarmService.shared.refreshExisting() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await WorkdayAlarmService.shared.refreshExisting() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await WorkdayAlarmService.shared.refreshExisting() }
            }
#endif
        }
    }
}
