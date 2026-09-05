import Photos
import UIKit

enum PhotoPersistence {
    private static let queue = DispatchQueue(label: "lowpolycam.photo.storage", qos: .utility)

    /// Stage before requesting Photos access. Denial, iCloud failures, and
    /// background expiration must never discard the only copy of a capture.
    static func save(data: Data, name: String, destination: SaveLocation,
                     completion: @escaping (URL?, String?, String?) -> Void) {
        queue.async {
            let url = CameraRecorder.clipsDirectory.appendingPathComponent(name)
            do { try data.write(to: url, options: .atomic) }
            catch { completion(nil, nil, error.localizedDescription); return }
            guard destination == .photos else { completion(url, nil, nil); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    completion(url, nil, "Photos access denied · Photo kept in Files")
                    return
                }
                var identifier: String?
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    request.addResource(with: .photo, fileURL: url, options: options)
                    identifier = request.placeholderForCreatedAsset?.localIdentifier
                } completionHandler: { success, error in
                    completion(url, success ? identifier : nil,
                               success ? nil : "Photos import failed · Photo kept in Files: \(error?.localizedDescription ?? "Unknown error")")
                }
            }
        }
    }

    static func thumbnail(_ image: UIImage) -> UIImage {
        let scale = min(1, 600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
