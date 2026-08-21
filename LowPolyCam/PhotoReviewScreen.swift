import SwiftUI
import UIKit

// MARK: - Photo 2.0: Post-Capture Review
//
// Shown right after a photo (or burst) finishes saving, mirroring stock
// Camera's "tap the thumbnail" review but opened automatically when the
// user has `settings.photoReviewAfterCapture` on. For a single photo this
// is one full-screen image with Keep/Delete/Share. For a burst it becomes
// a horizontal swipe-through of every frame in that burst, each with the
// same actions, so a burst can be culled down to the keepers in place
// instead of scrolling the whole clip gallery.
//
// Layout is built for the smallest supported screen (iPhone 7, 375×667pt):
// a single row of three equal-width action buttons, no icon that can wrap
// or get pushed off-screen, and one fixed-height bottom bar so nothing
// shifts as the user swipes between burst frames of different sizes.

struct PhotoReviewScreen: View {
    @ObservedObject var settings: AppSettings
    let item: PhotoReviewItem?
    let burstItems: [PhotoReviewItem]

    @Environment(\.presentationMode) private var presentation
    @State private var selection: Int = 0
    @State private var deletedIDs: Set<UUID> = []
    @State private var shareItem: ShareableImage?
    @State private var showDeleteConfirm = false

    /// The frames actually available to browse. A burst review shows every
    /// frame from that burst; a single-shot review shows just the one item.
    private var frames: [PhotoReviewItem] {
        let source = burstItems.isEmpty ? (item.map { [$0] } ?? []) : burstItems
        return source.filter { !deletedIDs.contains($0.id) }
    }

    private var isBurst: Bool { burstItems.count > 1 }

    var body: some View {
        NavigationView {
            ZStack {
                Palette.slateDeep.ignoresSafeArea()

                if frames.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        TabView(selection: $selection) {
                            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                                Image(uiImage: frame.image)
                                    .resizable()
                                    .scaledToFit()
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(PageTabViewStyle(indexDisplayMode: isBurst ? .always : .never))
                        // Fixed frame so paging between differently-sized burst
                        // frames never resizes the bar below it.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isBurst {
                            Text("Frame \(min(selection + 1, frames.count)) of \(frames.count)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.bottom, 6)
                        }

                        actionBar
                    }
                }
            }
            .navigationBarTitle(isBurst ? "Burst Review" : "Review", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                presentation.wrappedValue.dismiss()
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .accentColor(settings.accentColor.color)
        .sheet(item: $shareItem) { wrapper in
            PhotoReviewShareSheet(items: [wrapper.image])
        }
        .actionSheet(isPresented: $showDeleteConfirm) {
            ActionSheet(
                title: Text("Delete this photo?"),
                message: Text("This removes the file from where it was saved."),
                buttons: [
                    .destructive(Text("Delete")) { deleteCurrentFrame() },
                    .cancel()
                ]
            )
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            reviewButton(title: "Delete", icon: "trash", tint: Palette.record) {
                showDeleteConfirm = true
            }
            reviewButton(title: "Share", icon: "square.and.arrow.up", tint: .white) {
                guard let frame = currentFrame else { return }
                shareItem = ShareableImage(image: frame.image)
            }
            reviewButton(title: "Keep", icon: "checkmark", tint: settings.accentColor.bright) {
                presentation.wrappedValue.dismiss()
            }
        }
        .padding(.horizontal, 14)
        // Fixed height bar — never grows/shrinks with content, so it can't
        // shift position between burst frames or screen sizes.
        .frame(height: 76)
        .background(
            Palette.panel.opacity(0.96)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func reviewButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(tint)
            // Equal-width buttons that always fill the row — on the
            // narrowest supported screen (iPhone 7, 375pt) this keeps all
            // three labels centered under their icons with no wrapping.
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            Text("Nothing to review")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: Helpers

    private var currentFrame: PhotoReviewItem? {
        guard frames.indices.contains(selection) else { return frames.first }
        return frames[selection]
    }

    private func deleteCurrentFrame() {
        guard let frame = currentFrame else { return }
        if let url = frame.url {
            try? FileManager.default.removeItem(at: url)
        }
        deletedIDs.insert(frame.id)
        if frames.isEmpty {
            presentation.wrappedValue.dismiss()
        } else {
            selection = min(selection, frames.count - 1)
        }
    }
}

// MARK: - Sharing plumbing

private struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct PhotoReviewShareSheet: UIViewControllerRepresentable {
    let items: [UIImage]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
