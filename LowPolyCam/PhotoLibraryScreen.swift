import SwiftUI
import Photos
import AVKit
import UniformTypeIdentifiers

/// iOS 15 Photos-library browser used by the camera thumbnail. It replaces
/// the app-files-only clip list for the main camera workflow, so captures
/// saved to Photos appear where people expect them to: behind the thumbnail.
///
/// v2 adds the controls people expect from a real "library" screen:
/// multi-select, delete (via the system Photos confirmation), share/AirDrop
/// of the original file(s), and a swipeable full-screen viewer instead of a
/// single locked preview.
struct PhotoLibraryScreen: View {
    @Environment(\.presentationMode) private var presentation

    @State private var assets: [PHAsset] = []
    @State private var authorization: PHAuthorizationStatus = .notDetermined

    @State private var isSelecting = false
    @State private var selection: Set<String> = []

    @State private var previewSelection: PreviewIndex?
    @State private var shareRequest: ShareRequest?
    @State private var isPreparingShare = false
    @State private var deleteError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationView {
            ZStack {
                Palette.slateDeep.ignoresSafeArea()

                if canBrowse {
                    if assets.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                } else if authorization == .notDetermined {
                    ProgressView()
                        .tint(Palette.violet)
                } else {
                    permissionState
                }

                if isPreparingShare {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
            }
            .navigationBarTitle("Library", displayMode: .inline)
            .navigationBarItems(leading: leadingBar, trailing: trailingBar)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    bottomBar
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.violet)
        .onAppear(perform: requestAccessAndLoad)
        .fullScreenCover(item: $previewSelection) { selection in
            PhotoLibraryPreview(
                assets: assets,
                startIndex: selection.index,
                onDelete: { asset in delete([asset]) }
            )
        }
        .sheet(item: $shareRequest) { request in
            ShareSheet(items: request.items)
        }
        .alert("Couldn't Delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "Unknown error")
        }
    }

    // MARK: Nav bar

    private var leadingBar: some View {
        Group {
            if canBrowse && !assets.isEmpty {
                Button(isSelecting ? "Cancel" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
            }
        }
    }

    private var trailingBar: some View {
        Button("Done") {
            isSelecting = false
            selection.removeAll()
            presentation.wrappedValue.dismiss()
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isSelecting {
            Button(action: deleteSelection) {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .foregroundColor(selection.isEmpty ? .white.opacity(0.3) : .red)

            Spacer()

            Text(selection.isEmpty ? "Select Items" : "\(selection.count) Selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            Button(action: shareSelection) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)
            .foregroundColor(selection.isEmpty ? .white.opacity(0.3) : Palette.violet.opacity(0.95))
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                    thumbnailButton(for: asset, index: index)
                }
            }
        }
    }

    private func thumbnailButton(for asset: PHAsset, index: Int) -> some View {
        let id = asset.localIdentifier
        return Button(action: {
            if isSelecting {
                toggle(id)
            } else {
                previewSelection = PreviewIndex(index: index)
            }
        }) {
            PhotoLibraryThumbnail(asset: asset, isSelecting: isSelecting, isSelected: selection.contains(id))
        }
        .buttonStyle(.plain)
        // Long-press mirrors the stock Photos app: jump straight into
        // selection mode with this item already picked, instead of forcing
        // a separate tap on "Select" first.
        .onLongPressGesture {
            if !isSelecting {
                isSelecting = true
            }
            selection.insert(id)
        }
    }

    private var canBrowse: Bool {
        authorization == .authorized || authorization == .limited
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36, weight: .medium))
                .foregroundColor(Palette.violet)
            Text("No Photos Yet")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Photos and videos saved to Photos will appear here.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var permissionState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(Palette.violet)
            Text("Allow Photo Access")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Enable Photos access in Settings to browse your camera library.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Selection

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Loading

    private func requestAccessAndLoad() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorization = current
        if current == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    authorization = status
                    if status == .authorized || status == .limited { loadAssets() }
                }
            }
        } else if current == .authorized || current == .limited {
            loadAssets()
        }
    }

    private func loadAssets() {
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)
            var loaded: [PHAsset] = []
            loaded.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in loaded.append(asset) }
            DispatchQueue.main.async { assets = loaded }
        }
    }

    // MARK: Delete

    private func deleteSelection() {
        let toDelete = assets.filter { selection.contains($0.localIdentifier) }
        delete(toDelete)
    }

    /// Deletes assets from the Photos library. `performChanges` itself
    /// triggers the system's native "Delete X items?" confirmation, so we
    /// don't show a second, app-level confirmation on top of it.
    private func delete(_ toDelete: [PHAsset]) {
        guard !toDelete.isEmpty else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
                guard success else {
                    // User cancelling the system confirmation also lands
                    // here with a nil error — only surface real failures.
                    if let error = error {
                        deleteError = error.localizedDescription
                    }
                    return
                }
                let deletedIDs = Set(toDelete.map { $0.localIdentifier })
                assets.removeAll { deletedIDs.contains($0.localIdentifier) }
                selection.subtract(deletedIDs)
                if let current = previewSelection, current.index >= assets.count {
                    previewSelection = assets.isEmpty ? nil : PreviewIndex(index: assets.count - 1)
                }
                if assets.isEmpty { isSelecting = false }
            }
        }
    }

    // MARK: Share

    private func shareSelection() {
        let toShare = assets.filter { selection.contains($0.localIdentifier) }
        share(toShare)
    }

    private func share(_ toShare: [PHAsset]) {
        guard !toShare.isEmpty, !isPreparingShare else { return }
        isPreparingShare = true
        exportForSharing(toShare) { urls in
            DispatchQueue.main.async {
                isPreparingShare = false
                guard !urls.isEmpty else { return }
                shareRequest = ShareRequest(items: urls)
            }
        }
    }

    /// Writes each asset's original file bytes to a temp file so the share
    /// sheet can offer the real photo/video (correct extension, full
    /// quality) rather than a re-encoded copy.
    private func exportForSharing(_ assets: [PHAsset], completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            var results: [Int: URL] = [:]
            let lock = NSLock()

            for (index, asset) in assets.enumerated() {
                guard let resource = preferredResource(for: asset) else { continue }
                let ext = fileExtension(for: resource)
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)

                group.enter()
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(for: resource, toFile: tmpURL, options: options) { error in
                    if error == nil {
                        lock.lock()
                        results[index] = tmpURL
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                let ordered = results.keys.sorted().compactMap { results[$0] }
                completion(ordered)
            }
        }
    }

    private func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first { $0.type == .video } ?? resources.first
        }
        return resources.first { $0.type == .photo } ?? resources.first
    }

    private func fileExtension(for resource: PHAssetResource) -> String {
        if let type = UTType(resource.uniformTypeIdentifier), let ext = type.preferredFilenameExtension {
            return ext
        }
        return resource.type == .video ? "mov" : "jpg"
    }
}

private struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [URL]
}

/// Wraps a grid index so it can drive `.fullScreenCover(item:)`, which
/// requires an `Identifiable` — a bare `Int?` can't be used there.
private struct PreviewIndex: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct PhotoLibraryThumbnail: View {
    let asset: PHAsset
    let isSelecting: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Palette.panel
                }
            }
            // Square shape comes from aspectRatio alone — no GeometryReader.
            // A GeometryReader here previously proposed extra height beyond
            // the square (it fills all space offered, not just the width),
            // so each cell's tappable area silently overflowed into the row
            // below and taps near the bottom of a thumbnail sometimes hit
            // the wrong photo. Removing it makes the tappable bounds exactly
            // match the visible square.
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .opacity(isSelecting && !isSelected ? 0.55 : 1)

            if asset.mediaType == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                    .padding(5)
            }

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? Palette.violet : .white)
                    .background(Circle().fill(Color.black.opacity(0.45)).padding(-1))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onAppear(perform: loadImage)
    }

    private func loadImage() {
        guard image == nil else { return }
        // Fixed target size instead of a measured GeometryReader width —
        // slightly less pixel-perfect, but thumbnails are small enough that
        // the difference isn't visible, and it avoids the layout bug above.
        let side = UIScreen.main.bounds.width / 3
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        PHCachingImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side * UIScreen.main.scale, height: side * UIScreen.main.scale),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result = result { image = result }
        }
    }
}

/// Full-screen, swipeable viewer for the whole library — replaces the old
/// single-locked-asset preview. Swiping moves between photos the same way
/// stock Photos does, and Delete/Share are one tap away instead of only
/// being available from the grid's multi-select bar.
private struct PhotoLibraryPreview: View {
    let assets: [PHAsset]
    let startIndex: Int
    let onDelete: (PHAsset) -> Void

    @Environment(\.presentationMode) private var presentation
    @State private var index: Int
    @State private var shareRequest: PreviewShareRequest?
    @State private var isPreparingShare = false

    init(assets: [PHAsset], startIndex: Int, onDelete: @escaping (PHAsset) -> Void) {
        self.assets = assets
        self.startIndex = startIndex
        self.onDelete = onDelete
        _index = State(initialValue: startIndex)
    }

    private var currentAsset: PHAsset? {
        assets.indices.contains(index) ? assets[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { i, asset in
                    PhotoLibraryPreviewPage(asset: asset)
                        .tag(i)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

            if isPreparingShare {
                Color.black.opacity(0.35).ignoresSafeArea()
                ProgressView().tint(.white).scaleEffect(1.2)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .sheet(item: $shareRequest) { request in
            ShareSheet(items: [request.item])
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: { presentation.wrappedValue.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
        }
        .padding()
    }

    private var bottomBar: some View {
        HStack {
            // No app-level confirmation here — PHPhotoLibrary's own delete
            // change already triggers the system's native confirmation, so
            // adding one of our own would show two prompts back to back.
            previewButton(icon: "trash") { deleteCurrent() }
            Spacer()
            previewButton(icon: "square.and.arrow.up") { shareCurrent() }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func previewButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
        .disabled(currentAsset == nil)
    }

    private func deleteCurrent() {
        guard let asset = currentAsset else { return }
        onDelete(asset)
        // The parent view removes the asset from its own array; here we
        // just make sure paging past the deleted item doesn't run off the
        // end of the (now stale, one item too long) local `assets` array.
        if assets.count <= 1 {
            presentation.wrappedValue.dismiss()
        }
    }

    private func shareCurrent() {
        guard let asset = currentAsset, !isPreparingShare else { return }
        isPreparingShare = true
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = (asset.mediaType == .video ? resources.first { $0.type == .video } : resources.first { $0.type == .photo }) ?? resources.first
        guard let resource = resource else {
            isPreparingShare = false
            return
        }
        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
            ?? (resource.type == .video ? "mov" : "jpg")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: tmpURL, options: options) { error in
            DispatchQueue.main.async {
                isPreparingShare = false
                guard error == nil else { return }
                shareRequest = PreviewShareRequest(item: tmpURL)
            }
        }
    }
}

private struct PreviewShareRequest: Identifiable {
    let id = UUID()
    let item: URL
}

/// One page of the swipeable preview. Kept as its own view (rather than
/// inline in the TabView) so each page loads and tears down its own
/// image/player independently — paging away from a playing video pauses it
/// instead of leaving audio running behind the next page.
private struct PhotoLibraryPreviewPage: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if asset.mediaType == .video, let player = player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            if asset.mediaType == .video {
                loadVideo()
            } else {
                loadImage()
            }
        }
    }

    private func loadImage() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHCachingImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 2048, height: 2048),
            contentMode: .aspectFit,
            options: options
        ) { result, _ in
            image = result
        }
    }

    private func loadVideo() {
        guard player == nil else { return }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        PHCachingImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            guard let avAsset = avAsset else { return }
            DispatchQueue.main.async {
                player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
            }
        }
    }
}

/// Thin UIKit bridge so we can AirDrop / share one or more original
/// photo/video files without leaving the app.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
