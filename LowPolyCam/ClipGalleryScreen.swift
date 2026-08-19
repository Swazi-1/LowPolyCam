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
    @State private var shareItems: [URL]?
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteOld = false
    @State private var confirmDeleteSelection = false
    @State private var playingClip: RecordedClip?
    @State private var renameClip: RecordedClip?
    @State private var renameText: String = ""

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
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                } else if clips.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationBarTitle("Recorded Clips", displayMode: .inline)
            .navigationBarItems(
                leading: Button(isEditing ? "Cancel" : "Done") {
                    if isEditing {
                        isEditing = false
                        selection.removeAll()
                    } else {
                        presentation.wrappedValue.dismiss()
                    }
                },
                trailing: trailingBar
            )
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    bottomBar
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
        .onAppear(perform: reload)
        .sheet(item: $playingClip) { clip in
            if clip.isPhoto {
                PhotoPreviewView(url: clip.url)
            } else {
                ClipPlayerView(url: clip.url)
            }
        }
        .sheet(item: shareBinding) { wrapper in
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
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Facet(sides: 6, rotation: .pi / 6)
                    .fill(Palette.slateMid.opacity(0.6))
                    .frame(width: 88, height: 88)
                Facet(sides: 6, rotation: .pi / 6)
                    .stroke(Palette.mint.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 88, height: 88)
                Image(systemName: "film.stack")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(Palette.mintBright)
            }
            .shadow(color: Palette.mint.opacity(0.2), radius: 16)

            Text("No Clips Yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Recordings and photos saved in the app will show up here.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(clips) { clip in
                    row(for: clip)
                }
            } header: {
                Text("\(clips.count) clip\(clips.count == 1 ? "" : "s") · \(totalSizeLabel)")
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .listStyle(.insetGrouped)
        .modifier(HiddenScrollBackground())
    }

    private func row(for clip: RecordedClip) -> some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: selection.contains(clip.url) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selection.contains(clip.url) ? Palette.mintBright : .white.opacity(0.35))
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
                                colors: [Palette.mintBright, Palette.mint],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: Palette.mint.opacity(0.3), radius: 4, y: 2)

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
            Button { shareItems = [clip.url] } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(Palette.mintDeep)
            Button {
                renameText = (clip.url.deletingPathExtension().lastPathComponent)
                renameClip = clip
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Palette.violetDeep)
        }
    }

    // MARK: Bars

    private var trailingBar: some View {
        Group {
            if !clips.isEmpty {
                if isEditing {
                    Button(selection.count == clips.count ? "Deselect All" : "Select All") {
                        if selection.count == clips.count {
                            selection.removeAll()
                        } else {
                            selection = Set(clips.map { $0.url })
                        }
                    }
                    .foregroundColor(Palette.mintBright)
                } else {
                    Button("Select") { isEditing = true }
                        .foregroundColor(Palette.mintBright)
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
                shareItems = clips.filter { selection.contains($0.url) }.map { $0.url }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)
            .foregroundColor(selection.isEmpty ? .white.opacity(0.3) : Palette.mintBright)
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
        byteFormatter.string(fromByteCount: clips.reduce(0) { $0 + $1.fileSize })
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
                let duration = isVideo ? CMTimeGetSeconds(AVURLAsset(url: url).duration) : 0
                return RecordedClip(id: url, url: url, name: url.deletingPathExtension().lastPathComponent,
                                     createdAt: created, fileSize: size,
                                     duration: duration.isFinite ? duration : 0,
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
            }
            renameClip = nil
            reload()
        } catch {
            renameClip = nil
        }
    }

    private func delete(_ toDelete: [RecordedClip]) {
        let fm = FileManager.default
        for clip in toDelete {
            try? fm.removeItem(at: clip.url)
        }
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

    private var shareBinding: Binding<ShareWrapper?> {
        Binding<ShareWrapper?>(
            get: { shareItems.map { ShareWrapper(items: $0) } },
            set: { newValue in shareItems = newValue?.items }
        )
    }
}

/// iOS 16+ only modifier, applied conditionally so this still builds on older deployment targets.
private struct HiddenScrollBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
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
                    ProgressView().tint(Palette.mintBright).scaleEffect(1.2)
                }
            }
            .navigationBarTitle("Preview", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(Palette.mint)
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
