import SwiftUI
import AVFoundation
import UIKit

/// A single recorded clip or photo on disk, with metadata for display.
struct RecordedClip: Identifiable, Equatable {
    let id: URL
    let url: URL
    let name: String
    let createdAt: Date
    let fileSize: Int64
    let duration: TimeInterval
    let isPhoto: Bool

    static func == (lhs: RecordedClip, rhs: RecordedClip) -> Bool { lhs.id == rhs.id }
}

/// Tiny persisted set of favorited clip filenames. Keyed by filename (not
/// the full URL) since renaming a clip changes its URL but should keep it
/// favorited — see ClipGalleryScreen.commitRename, which migrates the key.
enum FavoritesStore {
    private static let key = "favoriteClipFilenames"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: key)
    }
}

/// v2.1 — "Recorded Clips" sheet: browse every clip saved in the app's
/// documents directory, batch-delete them (all / older-than-3-days /
/// selection), and AirDrop / share a selection without leaving the app.
struct ClipGalleryScreen: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.presentationMode) private var presentation

    @State private var clips: [RecordedClip] = []
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var selection: Set<URL> = []
    @State private var shareSheet: ShareWrapper?
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteOld = false
    @State private var confirmDeleteSelection = false
    @State private var playingClip: RecordedClip?
    @State private var renameClip: RecordedClip?
    @State private var renameText: String = ""
    @State private var renameError: String?
    @State private var favorites: Set<String> = FavoritesStore.load()
    @State private var showFavoritesOnly = false
    @State private var favoriteHaptic = UISelectionFeedbackGenerator()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        NavigationView {
            ZStack {
                Palette.slateDeep.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(Palette.violet.opacity(0.95)).scaleEffect(1.2)
                } else if clips.isEmpty {
                    emptyState
                } else if displayedClips.isEmpty {
                    favoritesEmptyState
                } else {
                    list
                }
            }
            .navigationBarTitle("Recorded Clips", displayMode: .inline)
            .navigationBarItems(
                // Select on the leading side; Done dismisses on the trailing
                // side (matches Settings and other sheets).
                leading: leadingBar,
                trailing: Button("Done") {
                    if isEditing {
                        isEditing = false
                        selection.removeAll()
                    }
                    presentation.wrappedValue.dismiss()
                }
            )
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    bottomBar
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.violet)
        .onAppear(perform: reload)
        .sheet(item: $playingClip) { clip in
            if clip.isPhoto {
                PhotoPreviewView(url: clip.url)
            } else {
                ClipPlayerView(url: clip.url)
            }
        }
        .sheet(item: $shareSheet) { wrapper in
            ShareSheet(items: wrapper.items)
        }
        .confirmationDialog("Delete all clips? This can't be undone.",
                             isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All \(clips.count) Clips", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete clips older than 3 days? This can't be undone.",
                             isPresented: $confirmDeleteOld, titleVisibility: .visible) {
            Button("Delete Older Clips", role: .destructive) { deleteOlderThanThreeDays() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(selection.count) selected clip\(selection.count == 1 ? "" : "s")?",
                             isPresented: $confirmDeleteSelection, titleVisibility: .visible) {
            Button("Delete Selected", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Clip", isPresented: Binding(
            get: { renameClip != nil },
            set: { if !$0 { renameClip = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renameClip = nil }
        } message: {
            Text("Enter a new name for this file.")
        }
        .alert("Rename Failed", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "Unknown error")
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Facet(sides: 6, rotation: .pi / 6)
                    .fill(Palette.slateMid.opacity(0.6))
                    .frame(width: 88, height: 88)
                Facet(sides: 6, rotation: .pi / 6)
                    .stroke(Palette.violet.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 88, height: 88)
                Image(systemName: "film.stack")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(Palette.violet.opacity(0.95))
            }
            .shadow(color: Palette.violet.opacity(0.2), radius: 16)

            Text("No Clips Yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("New recordings appear here. If you only used an older build that deleted local copies after Photos save, record a new clip and it will show up.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    /// Shown instead of `emptyState` when the Favorites filter is on but
    /// nothing has been starred yet — distinct from "no clips at all".
    private var favoritesEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "star")
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(Palette.amber.opacity(0.9))
            Text("No Favorites Yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Tap the star on any clip to pin it here.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    // MARK: Favorites filter

    /// `clips` narrowed to favorites when the filter is on, else all clips.
    private var displayedClips: [RecordedClip] {
        showFavoritesOnly ? clips.filter { favorites.contains($0.url.lastPathComponent) } : clips
    }

    private func isFavorite(_ clip: RecordedClip) -> Bool {
        favorites.contains(clip.url.lastPathComponent)
    }

    private func toggleFavorite(_ clip: RecordedClip) {
        let key = clip.url.lastPathComponent
        if favorites.contains(key) {
            favorites.remove(key)
        } else {
            favorites.insert(key)
        }
        FavoritesStore.save(favorites)
        if settings.hapticFeedbackEnabled { favoriteHaptic.selectionChanged() }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(displayedClips) { clip in
                    row(for: clip)
                }
            } header: {
                Text("\(displayedClips.count) clip\(displayedClips.count == 1 ? "" : "s") · \(totalSizeLabel)")
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for clip: RecordedClip) -> some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: selection.contains(clip.url) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selection.contains(clip.url) ? Palette.violet.opacity(0.95) : .white.opacity(0.35))
                    .font(.system(size: 20))
            }

            Image(systemName: clip.isPhoto ? "photo.fill" : "film.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Palette.slateDeep)
                .frame(width: 32, height: 32)
                .background(
                    Facet(sides: 6, rotation: .pi / 6)
                        .fill(
                            LinearGradient(
                                colors: [Palette.violet.opacity(0.95), Palette.violet],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: Palette.violet.opacity(0.3), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(clip.isPhoto
                     ? "\(relativeDate(clip.createdAt)) · \(byteFormatter.string(fromByteCount: clip.fileSize))"
                     : "\(relativeDate(clip.createdAt)) · \(durationLabel(clip.duration)) · \(byteFormatter.string(fromByteCount: clip.fileSize))")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            if !isEditing {
                Button {
                    toggleFavorite(clip)
                } label: {
                    Image(systemName: isFavorite(clip) ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isFavorite(clip) ? Palette.amber : .white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(Palette.panel.opacity(0.6))
        .onTapGesture {
            if isEditing {
                toggle(clip.url)
            } else {
                playingClip = clip
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete([clip]) } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { shareSheet = ShareWrapper(items: [clip.url]) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(Palette.violetDeep)
            Button {
                renameText = (clip.url.deletingPathExtension().lastPathComponent)
                renameClip = clip
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Palette.violetDeep)
        }
        .swipeActions(edge: .leading) {
            Button { toggleFavorite(clip) } label: {
                Label(isFavorite(clip) ? "Unfavorite" : "Favorite",
                      systemImage: isFavorite(clip) ? "star.slash" : "star.fill")
            }
            .tint(Palette.amberDeep)
        }
    }

    // MARK: Bars

    private var leadingBar: some View {
        HStack(spacing: 16) {
            if isEditing {
                Button("Cancel") {
                    isEditing = false
                    selection.removeAll()
                }
                .foregroundColor(Palette.violet.opacity(0.95))
            } else {
                if !clips.isEmpty {
                    Button("Select") { isEditing = true }
                        .foregroundColor(Palette.violet.opacity(0.95))
                }
                Button {
                    showFavoritesOnly.toggle()
                    if settings.hapticFeedbackEnabled { favoriteHaptic.selectionChanged() }
                } label: {
                    Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                        .foregroundColor(showFavoritesOnly ? Palette.amber : Palette.violet.opacity(0.95))
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isEditing {
            Button {
                confirmDeleteSelection = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            .foregroundColor(selection.isEmpty ? .white.opacity(0.3) : .red)

            Spacer()

            Button {
                shareSheet = ShareWrapper(items: clips.filter { selection.contains($0.url) }.map { $0.url })
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)
            .foregroundColor(selection.isEmpty ? .white.opacity(0.3) : Palette.violet.opacity(0.95))
        } else if !clips.isEmpty {
            Button("Delete Older Than 3 Days") { confirmDeleteOld = true }
                .foregroundColor(.white.opacity(0.75))
            Spacer()
            Button("Delete All") { confirmDeleteAll = true }
                .foregroundColor(.red)
        }
    }

    // MARK: Helpers

    private var totalSizeLabel: String {
        byteFormatter.string(fromByteCount: displayedClips.reduce(0) { $0 + $1.fileSize })
    }

    private func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    private func relativeDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "--:--" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    // MARK: Data

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let dir = CameraRecorder.clipsDirectory
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

            let loaded: [RecordedClip] = files.compactMap { url in
                let ext = url.pathExtension.lowercased()
                let isVideo = (ext == "mov" || ext == "mp4")
                let isPhoto = (ext == "heic" || ext == "jpg" || ext == "jpeg")
                guard isVideo || isPhoto else { return nil }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let created = values?.creationDate ?? .distantPast
                let size = Int64(values?.fileSize ?? 0)
                // Prefer a quick duration read. For movie-fragment files the property
                // can be inaccurate until tracks are loaded; we accept a best-effort
                // value here to keep the gallery responsive on A10 / iPhone 7.
                var duration: TimeInterval = 0
                if isVideo {
                    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                    let sec = CMTimeGetSeconds(asset.duration)
                    duration = sec.isFinite ? sec : 0
                }
                return RecordedClip(id: url, url: url, name: url.deletingPathExtension().lastPathComponent,
                                     createdAt: created, fileSize: size,
                                     duration: duration,
                                     isPhoto: isPhoto)
            }.sorted { $0.createdAt > $1.createdAt }

            DispatchQueue.main.async {
                self.clips = loaded
                self.isLoading = false
            }
        }
    }

    private func commitRename() {
        guard let clip = renameClip else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameClip = nil
            return
        }
        // Keep original extension
        let ext = clip.url.pathExtension
        let safe = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let newURL = clip.url.deletingLastPathComponent()
            .appendingPathComponent(safe)
            .appendingPathExtension(ext)
        // Avoid overwriting an existing file
        var finalURL = newURL
        if FileManager.default.fileExists(atPath: finalURL.path), finalURL != clip.url {
            var i = 2
            while FileManager.default.fileExists(atPath: finalURL.path) {
                finalURL = clip.url.deletingLastPathComponent()
                    .appendingPathComponent("\(safe) \(i)")
                    .appendingPathExtension(ext)
                i += 1
            }
        }
        do {
            if finalURL != clip.url {
                try FileManager.default.moveItem(at: clip.url, to: finalURL)
                // Keep the favorite star attached to the renamed file —
                // favorites are keyed by filename, so the key must move too.
                let oldKey = clip.url.lastPathComponent
                if favorites.remove(oldKey) != nil {
                    favorites.insert(finalURL.lastPathComponent)
                    FavoritesStore.save(favorites)
                }
            }
            renameClip = nil
            reload()
        } catch {
            renameClip = nil
            renameError = "Could not rename: \(error.localizedDescription)"
        }
    }

    private func delete(_ toDelete: [RecordedClip]) {
        let fm = FileManager.default
        for clip in toDelete {
            try? fm.removeItem(at: clip.url)
            favorites.remove(clip.url.lastPathComponent)
        }
        FavoritesStore.save(favorites)
        let deletedURLs = Set(toDelete.map { $0.url })
        clips.removeAll { deletedURLs.contains($0.url) }
        selection.subtract(deletedURLs)
        if clips.isEmpty { isEditing = false }
    }

    private func deleteAll() {
        delete(clips)
    }

    private func deleteOlderThanThreeDays() {
        let cutoff = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        delete(clips.filter { $0.createdAt < cutoff })
    }

    private func deleteSelection() {
        delete(clips.filter { selection.contains($0.url) })
    }

    // MARK: Share sheet plumbing

    private struct ShareWrapper: Identifiable {
        let id = UUID()
        let items: [URL]
    }

}

/// Thin UIKit bridge so we can AirDrop / share multiple clip files at once.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Simple full-screen still-image preview for photos saved by the app,
/// mirroring ClipPlayerView's chrome so gallery browsing feels consistent
/// whether you tap a video or a photo.
struct PhotoPreviewView: View {
    let url: URL
    @Environment(\.presentationMode) private var presentation
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Palette.amber)
                            .shadow(color: Palette.amber.opacity(0.5), radius: 10)
                        Text("Unable to load photo")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("The photo file could not be found or opened.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding()
                } else {
                    ProgressView().tint(Palette.violet.opacity(0.95)).scaleEffect(1.2)
                }
            }
            .navigationBarTitle("Preview", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.violet)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = UIImage(contentsOfFile: url.path)
                DispatchQueue.main.async {
                    if let loaded = loaded {
                        self.image = loaded
                    } else {
                        self.loadFailed = true
                    }
                }
            }
        }
    }
}

