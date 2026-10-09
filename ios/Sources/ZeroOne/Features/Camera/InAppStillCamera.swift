import SwiftUI
import UIKit

/// Present only after an explicit user action and camera authorization.
/// The delegate returns a re-encoded picture once, with no library write or upload.
@MainActor
struct InAppStillCamera: UIViewControllerRepresentable {
    enum Result {
        case captured(Data)
        case cancelled
        case failed
    }

    let onFinish: (Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.cameraCaptureMode = .photo
        camera.allowsEditing = false
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (Result) -> Void
        private var didFinish = false

        init(onFinish: @escaping (Result) -> Void) { self.onFinish = onFinish }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(.cancelled) }

        func imagePickerController(_ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let picture = info[.originalImage] as? UIImage,
                  let data = picture.jpegData(compressionQuality: 0.95) else {
                finish(.failed)
                return
            }
            finish(.captured(data))
        }

        private func finish(_ result: Result) {
            guard !didFinish else { return }
            didFinish = true
            onFinish(result)
        }
    }
}
