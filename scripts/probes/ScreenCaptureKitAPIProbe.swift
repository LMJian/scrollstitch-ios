// Compile-only feasibility probe. Not linked into the app and never executed.
// It checks iOS symbols against the selected SDK with the iOS 27 floor.
import Foundation
import CoreMedia
import ImageIO
import ScreenCaptureKit

@available(iOS 27.0, *)
final class ScreenCaptureKitAPIProbe: NSObject, SCContentSharingPickerObserver,
    SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "dev.scrollstitch.api-probe")

    @MainActor func presentFullDisplayPicker() -> Bool {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { return false }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
        return true
    }

    func makeStream(filter: SCContentFilter) throws -> SCStream {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        return stream
    }

    func start(_ stream: SCStream) async throws { try await stream.startCapture() }
    func stop(_ stream: SCStream) async throws { try await stream.stopCapture() }

    @MainActor func detachPicker() { SCContentSharingPicker.shared.remove(self) }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {}
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {}
    func stream(_ stream: SCStream, didStopWithError error: any Error) {}
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let rawOrientation = attachments?.first?[.videoOrientation] as? UInt32
        let orientation = rawOrientation.flatMap(CGImagePropertyOrientation.init(rawValue:))
        _ = orientation
        _ = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }
}

@MainActor func captureBackendAvailabilityProbe() -> Bool {
    return SCContentSharingPicker.shared.isAvailable
}
