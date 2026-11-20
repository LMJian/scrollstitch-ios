#if canImport(ScreenCaptureKit)
import UIKit

final class ScrollAppDelegate:NSObject,UIApplicationDelegate {
    func applicationProtectedDataWillBecomeUnavailable(_ application:UIApplication) {
        ScrollCaptureCoordinator.shared.protectedDataUnavailable()
    }
    func applicationProtectedDataDidBecomeAvailable(_ application:UIApplication) {
        Task {await ScrollCaptureCoordinator.shared.recover()}
    }
}
#endif
