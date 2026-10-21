import SwiftUI
import UIKit
import Photos

struct PhotoKitWriter: PhotoLibraryWriting {
    private static func map(_ value: PHAuthorizationStatus) -> PhotoAuthorization {
        switch value {
        case .authorized, .limited: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
    func authorization() async -> PhotoAuthorization { Self.map(PHPhotoLibrary.authorizationStatus(for:.addOnly)) }
    func requestAddOnly() async -> PhotoAuthorization { Self.map(await PHPhotoLibrary.requestAuthorization(for:.addOnly)) }
    func write(fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options=PHAssetResourceCreationOptions()
            options.shouldMoveFile=false
            PHAssetCreationRequest.forAsset().addResource(with:.photo,fileURL:fileURL,options:options)
        }
    }
}

/// The system owns consumption timing; keep the immutable file alive until dismissal.
final class ImageShareSession: Identifiable {
    let id=UUID()
    let accesses: [ResultAccess]
    init(accesses:[ResultAccess]) { self.accesses=accesses }
}
struct ImageShareActivity: UIViewControllerRepresentable {
    let session: ImageShareSession
    let onComplete: @MainActor (Bool,Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller=UIActivityViewController(activityItems:session.accesses.map(\.url),applicationActivities:nil)
        controller.completionWithItemsHandler = { _,completed,_,error in
            let failed=error != nil
            Task { @MainActor in onComplete(completed,failed) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
