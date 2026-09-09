import SwiftUI

struct VideoSettingsView: View {
    @Environment(\.cameraTint) private var theme
    @ObservedObject var camera: CameraManager
    var positionStats: () -> Void = {}
    @AppStorage("photoAspect") private var photoAspect = "4:3"
    @AppStorage("burstCount") private var burstCount = 5
    @AppStorage("appColorScheme") private var appColorScheme = "system"
    @State private var showingPhotoMegapixelMenu = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    Button {
                        camera.switchCamera()
                    } label: {
                        SettingsHeroRow(
                            symbol: modeSymbol,
                            title: "\(modeTitle) • \(camera.cameraPosition == .back ? "Rear" : "Front")",
                            subtitle: heroSubtitle
                        )
                    }
                    .buttonStyle(.plain)

                    SettingsAppearanceQuickRow(selection: $appColorScheme)

                    switch camera.captureMode {
                    case .video:
                        videoQualitySettings
                    case .sloMo:
                        slowMotionSettings
                    case .photo:
                        photoSettings
                    }

                    QuickCameraSettings(camera: camera)

                    if camera.recoverableRecordingCount > 0 {
                        recoveryCard
                    }

                    moreSettingsSection

                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsHeroRow(
                            symbol: "paintpalette.fill",
                            title: "Appearance",
                            subtitle: "Colors, UI & theme",
                            subtitleColor: .secondary
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(theme)
            .accentColor(theme)
            .preferredColorScheme(resolvedColorScheme(appColorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Settings")
                .font(.system(size: 32, weight: .bold))
            Spacer()
            Text("LowPolyCam")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme)
        }
        .padding(.bottom, 2)
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Recovery")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(camera.recoverableRecordingCount) recording\(camera.recoverableRecordingCount == 1 ? "" : "s") waiting")
                        .font(.subheadline.weight(.semibold))
                    Text("Retry saving recordings that Photos could not import earlier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") {
                    camera.retryRecoverableRecordings()
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.primary.opacity(0.05)))
        }
    }

    private var moreSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "More Settings", subtitle: "Customize your recording experience")
            SettingsGrid {
                if camera.captureMode == .video {
                    NavigationLink {
                        VideoPresetsView(camera: camera)
                    } label: {
                        SettingsGridNavRow(symbol: "wand.and.stars", title: "Video Presets", subtitle: "Save favorite setups")
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    CapturePreferencesView(camera: camera)
                } label: {
                    SettingsGridNavRow(symbol: "slider.horizontal.3", title: "Capture", subtitle: "Timer, shutter, audio")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ViewfinderHUDSettingsView(camera: camera)
                } label: {
                    SettingsGridNavRow(symbol: "rectangle", title: "Viewfinder & HUD", subtitle: "On-screen tools")
                }
                .buttonStyle(.plain)

                if camera.captureMode != .photo {
                    NavigationLink {
                        AdvancedRecordingSettingsView(camera: camera, positionStats: positionStats)
                    } label: {
                        SettingsGridNavRow(symbol: "waveform.path.ecg", title: "Advanced Recording", subtitle: "Pro options and diagnostics")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var videoQualitySettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Video Settings")
            SettingsGrid {
                SettingsOptionCard(
                    symbol: "aspectratio",
                    title: "Resolution",
                    subtitle: "Video size",
                    options: VideoResolution.allCases,
                    selection: camera.selectedResolution,
                    label: { $0.rawValue },
                    isEnabled: camera.isVideoResolutionSupported,
                    onSelect: camera.selectResolution
                )
                SettingsOptionCard(
                    symbol: "speedometer",
                    title: "Frame Rate",
                    subtitle: "Frames per second",
                    options: VideoFrameRate.allCases,
                    selection: camera.selectedFrameRate,
                    label: { $0.label },
                    isEnabled: camera.isVideoFrameRateSupported,
                    onSelect: camera.selectFrameRate
                )
                SettingsOptionCard(
                    symbol: "square.stack.3d.up.fill",
                    title: "Compression",
                    subtitle: "File size vs quality",
                    options: VideoCompression.allCases,
                    selection: camera.videoCompression,
                    label: { $0.rawValue },
                    onSelect: { camera.videoCompression = $0 }
                )
                SettingsOptionCard(
                    symbol: "film.fill",
                    title: "Codec",
                    subtitle: "Video encoding format",
                    options: ["HEVC", "H264"],
                    selection: camera.selectedVideoCodec,
                    label: { $0 == "HEVC" ? "HEVC" : "H.264" },
                    isEnabled: camera.isVideoCodecSupported,
                    onSelect: { camera.selectedVideoCodec = $0 }
                )
            }
            if let message = camera.codecAvailabilityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var slowMotionSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Slo-Mo Settings")
            Text("HEVC / H.265 is used automatically for reliable high-frame-rate recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if camera.cameraPosition == .back && camera.minimumZoomFactor >= 1 {
                Text("0.5× is available only when the Ultra Wide lens supports this Slo-Mo quality and frame rate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if camera.supportedSlowMotionResolutions.isEmpty {
                Text("Slo-Mo isn’t available on this camera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                SettingsGrid {
                    SettingsOptionCard(
                        symbol: "aspectratio",
                        title: "Resolution",
                        subtitle: "Video size",
                        options: VideoResolution.allCases,
                        selection: camera.selectedSlowMotionResolution,
                        label: { $0.rawValue },
                        isEnabled: camera.isSlowMotionResolutionSupported,
                        onSelect: camera.selectSlowMotionResolution
                    )
                    SettingsOptionCard(
                        symbol: "speedometer",
                        title: "Frame Rate",
                        subtitle: "Frames per second",
                        options: CameraManager.SlowMotionFrameRate.allCases,
                        selection: camera.selectedSlowMotionFrameRate,
                        label: { $0.label },
                        isEnabled: camera.isSlowMotionFrameRateSupported,
                        onSelect: camera.selectSlowMotionFrameRate
                    )
                }
            }
        }
    }

    private var photoSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Photo Settings")
            SettingsGrid {
                SettingsOptionCard(
                    symbol: "crop",
                    title: "Aspect Ratio",
                    subtitle: "Photo shape",
                    options: ["4:3", "1:1"],
                    selection: photoAspect,
                    label: { $0 },
                    onSelect: { photoAspect = $0 }
                )
                SettingsOptionCard(
                    symbol: "square.stack.3d.up.fill",
                    title: "Burst Photos",
                    subtitle: "Shots per burst",
                    options: [5, 10, 15],
                    selection: burstCount,
                    label: { "\($0)" },
                    onSelect: { burstCount = $0 }
                )
                SettingsOptionCard(
                    symbol: "doc.fill",
                    title: "Save Format",
                    subtitle: "HEIC saves space",
                    options: ["HEIC", "JPEG"],
                    selection: camera.photoFileFormat,
                    label: { $0 },
                    onSelect: { camera.photoFileFormat = $0 }
                )
            }
            Text("Hold the shutter to burst. Release to stop early. Each photo saves separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
            photoQualityRow
        }
        .onAppear { camera.updatePhotoAspectSelection(photoAspect) }
        .onChange(of: photoAspect) { _, newAspect in
            camera.updatePhotoAspectSelection(newAspect)
        }
    }

    private var photoQualityRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.metering.matrix")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("Photo Quality")
                    .font(.system(size: 15, weight: .semibold))
                Text("Full sensor quality, saved at the selected MP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                showingPhotoMegapixelMenu.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(camera.currentPhotoResolutionLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(theme)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.opacity(0.13), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPhotoMegapixelMenu, arrowEdge: .trailing) {
                VStack(spacing: 0) {
                    ForEach(camera.supportedPhotoMegapixels, id: \.self) { megapixels in
                        Button {
                            camera.selectPhotoMegapixels(megapixels)
                            showingPhotoMegapixelMenu = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 18)
                                    .opacity(megapixels == camera.selectedPhotoMegapixels ? 1 : 0)

                                Text("\(megapixels) MP")
                                    .font(.system(size: 16, weight: .regular))

                                Spacer(minLength: 18)
                            }
                            .foregroundStyle(.primary)
                            .frame(width: 176, height: 36, alignment: .leading)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .fixedSize(horizontal: true, vertical: true)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.clear)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.primary.opacity(0.05)))
    }

    private var modeSymbol: String {
        switch camera.captureMode {
        case .video: return "video.fill"
        case .photo: return "camera.fill"
        case .sloMo: return "slowmo"
        }
    }

    private var modeTitle: String {
        switch camera.captureMode {
        case .video: return "Video"
        case .photo: return "Photo"
        case .sloMo: return "Slo-Mo"
        }
    }

    private var heroSubtitle: String {
        switch camera.captureMode {
        case .video:
            let codec = camera.selectedVideoCodec == "HEVC" ? "HEVC" : "H.264"
            return "\(camera.selectedResolution.rawValue) • \(camera.selectedFrameRate.rawValue) fps • \(codec) • \(camera.videoCompression.rawValue)"
        case .sloMo:
            return "\(camera.selectedSlowMotionResolution.rawValue) • \(camera.selectedSlowMotionFrameRate.rawValue) fps • Slo-Mo"
        case .photo:
            return "\(camera.currentPhotoResolutionLabel) • \(camera.photoFileFormat) • \(photoAspect)"
        }
    }
}
