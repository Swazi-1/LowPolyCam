import Photos
import Combine

final class PhotoLibraryChanges: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var revision = 0
    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in self?.revision += 1 }
    }
}
