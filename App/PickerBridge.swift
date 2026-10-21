import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct CollagePickerRequest: Identifiable {
    let id=UUID()
    var taskID: UUID? = nil
    var revision: UInt64? = nil
    var replacing: UUID? = nil
    var limit: Int = 20
}

struct OrderedImagePicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 20
    var completion: ([PickerInput]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = max(1,min(20,selectionLimit))
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([PickerInput]) -> Void
        init(completion: @escaping ([PickerInput]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            var seen = Set<String>()
            let inputs = results.compactMap { result -> PickerInput? in
                if let id = result.assetIdentifier, !seen.insert(id).inserted { return nil }
                return PickerInput(id: UUID(), identifier: result.assetIdentifier, provider: result.itemProvider)
            }
            completion(inputs)
        }
    }
}
