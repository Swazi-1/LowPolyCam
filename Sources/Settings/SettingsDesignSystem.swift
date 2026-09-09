import SwiftUI

// MARK: - App theme (Light / Dark / System)

/// Resolves the stored "appColorScheme" preference ("light" / "dark" / "system")
/// into a SwiftUI ColorScheme override. `nil` means "follow the system".
func resolvedColorScheme(_ raw: String) -> ColorScheme? {
    switch raw {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
}

// MARK: - Section header ("VIDEO SETTINGS", "QUICK CONTROLS", ...)

struct SettingsSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.85))
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Icon badge (tinted rounded-square icon, used on hero rows)

struct SettingsIconBadge: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Shared rounded card surface

private struct SettingsCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.primary.opacity(0.05)))
    }
}

private extension View {
    func settingsCardSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(SettingsCardSurface(cornerRadius: cornerRadius))
    }
}

// MARK: - Hero row: icon + title/subtitle + optional chevron, own card background
// Used for the top "Video • Rear" summary and the bottom "Appearance" entry.

struct SettingsHeroRow: View {
    @Environment(\.cameraTint) private var theme
    let symbol: String
    let title: String
    let subtitle: String
    var subtitleColor: Color? = nil
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconBadge(symbol: symbol, tint: theme)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(subtitleColor ?? theme)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .settingsCardSurface()
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Inline "Appearance / App theme" row with a Light/Dark/System switcher

struct SettingsAppearanceQuickRow: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("App theme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            AppearanceModeSwitcher(selection: $selection)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .settingsCardSurface()
    }
}

struct AppearanceModeSwitcher: View {
    @Environment(\.cameraTint) private var theme
    @Binding var selection: String
    private let options: [(value: String, label: String, symbol: String)] = [
        ("light", "Light", "sun.max.fill"),
        ("dark", "Dark", "moon.fill"),
        ("system", "System", "gearshape.fill")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        Text(option.label)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(width: 52, height: 44)
                    .background(
                        selection == option.value ? theme : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .foregroundStyle(selection == option.value ? Color.black : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 2-column grid container

struct SettingsGrid<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            content
        }
    }
}

// MARK: - Option card: icon + title/subtitle atop a row of selectable pills

struct SettingsOptionCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let options: [(id: AnyHashable, label: String)]
    let selectedID: AnyHashable
    let isOptionEnabled: (AnyHashable) -> Bool
    let onSelect: (AnyHashable) -> Void
    @Environment(\.cameraTint) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                ForEach(options, id: \.id) { option in
                    let enabled = isOptionEnabled(option.id)
                    Button {
                        guard enabled else { return }
                        onSelect(option.id)
                    } label: {
                        HStack(spacing: 4) {
                            Text(option.label)
                                .font(.system(size: option.label.count > 8 ? 11 : 12, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                                .allowsTightening(true)
                            if !enabled {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            option.id == selectedID ? theme : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .foregroundStyle(
                            enabled
                                ? (option.id == selectedID ? Color.black : Color.primary)
                                : Color.secondary
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityLabel(enabled ? option.label : "\(option.label), locked")
                    .accessibilityHint(enabled ? "" : "Unavailable for the current camera format.")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface()
    }
}

extension SettingsOptionCard {
    /// Convenience initializer that works with any Hashable option type
    /// (enums, String, Int, ...) instead of hand-building AnyHashable pairs.
    init<Option: Hashable>(
        symbol: String,
        title: String,
        subtitle: String,
        options: [Option],
        selection: Option,
        label: (Option) -> String,
        isEnabled: @escaping (Option) -> Bool = { _ in true },
        onSelect: @escaping (Option) -> Void
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.options = options.map { (AnyHashable($0), label($0)) }
        self.selectedID = AnyHashable(selection)
        self.isOptionEnabled = { anyValue in
            guard let value = anyValue.base as? Option else { return false }
            return isEnabled(value)
        }
        self.onSelect = { anyValue in
            if let value = anyValue.base as? Option {
                onSelect(value)
            }
        }
    }
}

// MARK: - Grid navigation card: icon + chevron, then title/subtitle (used in "More Settings")

struct SettingsGridNavRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardSurface(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Navigation row: list-style row used inside a SettingsCard (no own background)

struct SettingsNavigationRow: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme)
                .frame(width: 34, height: 34)
                .background(theme.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Section card: caps header above a rounded content surface

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let contentSpacing: CGFloat
    let content: Content

    init(title: String, symbol: String, contentSpacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.contentSpacing = contentSpacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: title)
            VStack(alignment: .leading, spacing: contentSpacing) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardSurface(cornerRadius: 22)
        }
    }
}

// MARK: - Divider

struct SettingsDivider: View {
    var body: some View {
        Divider().opacity(0.4)
    }
}

// MARK: - Toggle row (optional leading icon)

struct SettingsToggleRow: View {
    @Environment(\.cameraTint) private var theme
    let title: String
    let subtitle: String
    var symbol: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(theme)
        .frame(minHeight: 50)
    }
}

// MARK: - Nested sub-row with an L-shaped connector (e.g. "Grid Opacity" under "Grid")

struct SettingsSubRow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsSubRowConnector()
                .frame(width: 20, height: 30)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 4)
    }
}

// MARK: - Non-scrolling page for short menus that should stay fixed in place

struct StaticSettingsPage<Content: View>: View {
    @Environment(\.cameraTint) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 14) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(theme)
    }
}

private struct SettingsSubRowConnector: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 0))
            path.addLine(to: CGPoint(x: 1, y: 12))
            path.addQuadCurve(to: CGPoint(x: 12, y: 15), control: CGPoint(x: 1, y: 15))
        }
        .stroke(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}
