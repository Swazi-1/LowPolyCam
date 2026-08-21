import SwiftUI
import Photos
import AVKit

/// iOS 15 Photos-library browser used by the camera thumbnail. It replaces
/// the app-files-only clip list for the main camera workflow, so captures
/// saved to Photos appear where people expect them to: behind the thumbnail.
struct PhotoLibraryScreen: View {
    @Environment(\.presentationMode) private var presentation

    @State private var assets: [PHAsset] = []
    @State private var authorization: PHAuthorizationStatus = .notDetermined
    @State private var selectedAsset: LibraryAsset?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationView {
            ZStack {
                Palette.slateDeep.ignoresSafeArea()

                if canBrowse {
                    if assets.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(assets, id: \.localIdentifier) { asset in
                                    Button(action: { selectedAsset = LibraryAsset(asset: asset) }) {
                                        PhotoLibraryThumbnail(asset: asset)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else if authorization == .notDetermined {
                    ProgressView()
                        .tint(Palette.violet)
                } else {
                    permissionState
                }
            }
            .navigationBarTitle("Library", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.violet)
        .onAppear(perform: requestAccessAndLoad)
        .sheet(item: $selectedAsset) { item in
            PhotoLibraryPreview(asset: item.asset)
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
}

private struct LibraryAsset: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

private struct PhotoLibraryThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
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
                .frame(width: proxy.size.width, height: proxy.size.width)
                .clipped()

                if asset.mediaType == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                        .padding(5)
                }
            }
            .onAppear { loadImage(side: proxy.size.width) }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func loadImage(side: CGFloat) {
        guard image == nil else { return }
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

private struct PhotoLibraryPreview: View {
    let asset: PHAsset
    @Environment(\.presentationMode) private var presentation
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
        .overlay(
            Button(action: { presentation.wrappedValue.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .padding(),
            alignment: .topTrailing
        )
    }

    private func loadImage() {
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
        PHCachingImageManager.default().requestAVAsset(forVideo: asset, options: nil) { asset, _, _ in
            guard let asset = asset else { return }
            DispatchQueue.main.async {
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
        }
    }
}
