#if !SCROLLSTITCH_COLLAGE_ONLY && canImport(ScreenCaptureKit)
import UIKit
import UserNotifications

final class ScrollAppDelegate:NSObject,UIApplicationDelegate,UNUserNotificationCenterDelegate {
    func application(_ application:UIApplication,
        didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]? = nil)->Bool {
        UNUserNotificationCenter.current().delegate=self
        return true
    }
    func applicationProtectedDataWillBecomeUnavailable(_ application:UIApplication) {
        ScrollCaptureCoordinator.shared.protectedDataUnavailable()
    }
    func applicationProtectedDataDidBecomeAvailable(_ application:UIApplication) {
        Task {await ScrollCaptureCoordinator.shared.recover()}
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,
        didReceive response:UNNotificationResponse) async {
        guard let value=response.notification.request.content.userInfo["scrollSession"] as? String,
              let id=UUID(uuidString:value) else {return}
        await MainActor.run {ScrollCaptureCoordinator.shared.openWork(id)}
    }
}
#endif
