import SwiftUI

/// Isolated design system for the non-terminal workspace screens.
///
/// Everything here is opt-in: a screen applies `.workspaceScreenTheme()` (or individual
/// styles) to its own content. Nothing in this file changes the global `AccentColor`,
/// the UIKit appearance proxies or the app-wide color scheme. The theme must not leak
/// into terminal destinations: apply the modifiers to individual screens, not to the
/// shared `NavigationStack` (see `workspaceScreenTheme()`).
enum WorkspaceTheme {
    // MARK: - Palette

    /// Screen background.
    static let bg = Color(themeHex: 0x070A1E)
    /// Card surface.
    static let surface = Color(themeHex: 0x10132C)
    /// Card surface while pressed.
    static let surface2 = Color(themeHex: 0x171B3C)
    /// Primary border.
    static let border = Color(themeHex: 0x262C52)
    /// Dimmed border.
    static let borderLo = Color(themeHex: 0x1A1E3C)
    /// Primary text.
    static let textHi = Color(themeHex: 0xF1F2FA)
    /// Secondary text.
    static let textLo = Color(themeHex: 0x7B81AC)
    /// Technical/dimmed text.
    static let textDim = Color(themeHex: 0x464C78)
    /// Accent.
    static let accent = Color(themeHex: 0x7278EE)
    /// Dimmed accent (inactive elements).
    static let accentDim = Color(themeHex: 0x4548A0)
    /// Light accent (text on accent backgrounds, bright badges).
    static let accentLight = Color(themeHex: 0x9EA3F2)
}

private extension Color {
    /// Color from an sRGB triplet, e.g. `0x070A1E`.
    init(themeHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Typography

extension Font {
    /// Space Grotesk for interface text; supports Dynamic Type.
    static func workspaceUI(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(Self.spaceGroteskName(for: weight), size: Self.baseSize(for: style), relativeTo: style)
    }

    /// JetBrains Mono for paths, branches, counters and technical data; supports Dynamic Type.
    static func workspaceMono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(Self.jetBrainsMonoName(for: weight), size: Self.baseSize(for: style), relativeTo: style)
    }

    /// PostScript names of the bundled Space Grotesk faces.
    private static func spaceGroteskName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium: "SpaceGrotesk-Medium"
        case .semibold, .bold, .heavy, .black: "SpaceGrotesk-SemiBold"
        default: "SpaceGrotesk-Regular"
        }
    }

    /// PostScript names of the bundled JetBrains Mono faces.
    private static func jetBrainsMonoName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "JetBrainsMono-Medium"
        default: "JetBrainsMono-Regular"
        }
    }

    /// Base sizes of the system text styles for `Font.custom(_:size:relativeTo:)`.
    private static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

// MARK: - Badge

/// Small accent badge: bright when active, dimmed when inactive.
struct WorkspaceBadge: View {
    let text: String
    var icon: String? = nil
    var isActive = true

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.workspaceUI(.caption2, weight: .medium))
            }
            Text(text)
                .font(.workspaceUI(.caption2, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? WorkspaceTheme.accentLight : WorkspaceTheme.textLo)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (isActive ? WorkspaceTheme.accent : WorkspaceTheme.accentDim).opacity(isActive ? 0.22 : 0.16),
            in: Capsule()
        )
    }
}

// MARK: - Card

extension WorkspaceTheme {
    /// Card corner radius.
    static let cardCornerRadius: CGFloat = 14
    /// Card border width.
    static let cardBorderWidth: CGFloat = 1
    /// Card inner padding.
    static let cardPadding: CGFloat = 14
}

private struct WorkspaceCardModifier: ViewModifier {
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .padding(WorkspaceTheme.cardPadding)
            .background(isPressed ? WorkspaceTheme.surface2 : WorkspaceTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceTheme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(WorkspaceTheme.border, lineWidth: WorkspaceTheme.cardBorderWidth)
            )
        // No shadows: cards are separated by background and border.
    }
}

extension View {
    /// Card: 14 pt inner padding, `surface` background (`surface-2` when pressed),
    /// 14 pt corner radius, 1 pt border, no shadows.
    func workspaceCard(isPressed: Bool = false) -> some View {
        modifier(WorkspaceCardModifier(isPressed: isPressed))
    }
}

// MARK: - Press state

/// Pressable card: `surface` background, `surface-2` while pressed.
struct WorkspaceCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .workspaceCard(isPressed: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: WorkspaceTheme.cardCornerRadius, style: .continuous))
    }
}

// MARK: - Card activity

extension WorkspaceTheme {
    /// Width of the active card's leading bar.
    static let activeBarWidth: CGFloat = 3
    /// Opacity of inactive cards (they remain fully interactive).
    static let inactiveOpacity: Double = 0.55
}

/// 3 pt leading bar: bright accent for active cards, dimmed for inactive ones.
struct WorkspaceActiveBar: View {
    var isActive = true

    var body: some View {
        Capsule()
            .fill(isActive ? WorkspaceTheme.accent : WorkspaceTheme.accentDim)
            .frame(width: WorkspaceTheme.activeBarWidth)
    }
}

private struct WorkspaceEmphasisModifier: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        content.opacity(isActive ? 1 : WorkspaceTheme.inactiveOpacity)
        // Deliberately no .disabled: inactive elements stay tappable.
    }
}

extension View {
    /// Dims inactive cards (≈55% opacity) without turning them into disabled controls.
    func workspaceEmphasis(isActive: Bool) -> some View {
        modifier(WorkspaceEmphasisModifier(isActive: isActive))
    }
}

// MARK: - Screen styling

private struct WorkspaceScreenThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(WorkspaceTheme.accent)
            .scrollContentBackground(.hidden)
            .toolbarBackground(WorkspaceTheme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    /// Applies the theme to one non-terminal screen: accent tint, hiding the system
    /// list background (screens draw their own `bg`), dark navigation bar.
    ///
    /// Important: apply the modifier to the content of an individual screen (inside a
    /// `.navigationDestination` case or at the screen root), not to the shared
    /// `NavigationStack` — otherwise the tint and bar styling spread to the terminal
    /// destination. Global `AccentColor`, UIKit appearance and the app color scheme
    /// are unchanged.
    func workspaceScreenTheme() -> some View {
        modifier(WorkspaceScreenThemeModifier())
    }

    /// Local navigation bar title in Space Grotesk (toolbar principal),
    /// without changing UIKit appearance — so the styling stays on this screen.
    func workspacePrincipalTitle(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.workspaceUI(.headline, weight: .semibold))
                    .foregroundStyle(WorkspaceTheme.textHi)
                    .lineLimit(1)
            }
        }
    }

    /// Local navigation bar title aligned to the leading edge
    /// (large Space Grotesk text); the styling stays on this screen.
    func workspaceLeadingTitle(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(title)
                    .font(.workspaceUI(.title2, weight: .semibold))
                    .foregroundStyle(WorkspaceTheme.textHi)
                    .lineLimit(1)
            }
        }
    }

    /// Dark `bg` screen background across the full area, including safe areas.
    /// Applied to an individual screen's content together with `workspaceScreenTheme()`.
    func workspaceScreenBackground() -> some View {
        background(WorkspaceTheme.bg.ignoresSafeArea())
    }

    /// `List` row under a card: no separator or system row background,
    /// 14 pt horizontal insets — the card draws its own background.
    func workspaceCardListRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }
}

// MARK: - Settings form

private struct WorkspaceFormScreenThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .workspaceScreenTheme()
            // Local public SwiftUI scheme: system form controls (placeholders,
            // pickers, menus, spinners) match the palette. Applied only to the
            // individual screen's content and never inherited by terminal destinations.
            .colorScheme(.dark)
    }
}

extension View {
    /// Applies the theme to a `Form`-based screen: like `workspaceScreenTheme()`, plus
    /// a local dark color scheme for system controls.
    func workspaceFormScreenTheme() -> some View {
        modifier(WorkspaceFormScreenThemeModifier())
    }

    /// `Form` row in the palette: `surface` background and a dimmed separator.
    func workspaceFormRow() -> some View {
        listRowBackground(WorkspaceTheme.surface)
            .listRowSeparatorTint(WorkspaceTheme.borderLo)
    }
}

/// `Form` section header in the palette: dimmed Space Grotesk text.
/// Uppercase is preserved — it is the native `Form` header styling.
struct WorkspaceFormSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.workspaceUI(.footnote, weight: .medium))
            .foregroundStyle(WorkspaceTheme.textLo)
    }
}

extension View {
    /// `Form` section footer in the palette: dimmed technical Space Grotesk text.
    func workspaceFormSectionFooter() -> some View {
        font(.workspaceUI(.footnote))
            .foregroundStyle(WorkspaceTheme.textDim)
    }
}

// MARK: - Sections and screen states

/// Themed list section header: dimmed Space Grotesk text on an opaque `bg`
/// background (so content does not show through while scrolling).
struct WorkspaceSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.workspaceUI(.footnote, weight: .medium))
            .foregroundStyle(WorkspaceTheme.textLo)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .padding(.horizontal, 14)
            .listRowInsets(EdgeInsets())
            .listRowBackground(WorkspaceTheme.bg)
    }
}

/// Themed empty state: dimmed icon, title and optional description.
struct WorkspaceEmptyState: View {
    let title: String
    let icon: String
    var description: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.workspaceUI(.title))
                .foregroundStyle(WorkspaceTheme.textDim)
            Text(title)
                .font(.workspaceUI(.headline, weight: .medium))
                .foregroundStyle(WorkspaceTheme.textLo)
                .multilineTextAlignment(.center)
            if let description {
                Text(description)
                    .font(.workspaceUI(.subheadline))
                    .foregroundStyle(WorkspaceTheme.textDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Themed loading state: spinner in the accent color with a caption.
struct WorkspaceLoadingState: View {
    let text: String
    /// Center on the full screen (for root waiting states).
    var fillsScreen = false

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(WorkspaceTheme.accent)
            Text(text)
                .font(.workspaceUI(.subheadline))
                .foregroundStyle(WorkspaceTheme.textLo)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsScreen ? .infinity : nil)
        .padding(.vertical, fillsScreen ? 0 : 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - File editor

extension TextEditor {
    /// Multi-line editor styling: JetBrains Mono, `text-hi` text,
    /// caret and selection in the accent color. The standard light `TextEditor`
    /// background is hidden — the screen `bg` background remains underneath.
    func workspaceEditorChrome() -> some View {
        font(.workspaceMono(.body))
            .foregroundStyle(WorkspaceTheme.textHi)
            .tint(WorkspaceTheme.accent)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - Previews

/// Sample card for theme previews: activity bar, title,
/// badge, branch and a long path. Previews only — no store or runtime mocks.
private struct WorkspaceThemePreviewCard: View {
    var isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceActiveBar(isActive: isActive)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(isActive ? "payments-service" : "nightly-maintenance")
                        .font(.workspaceUI(.headline, weight: .semibold))
                        .foregroundStyle(WorkspaceTheme.textHi)
                        .lineLimit(1)
                    WorkspaceBadge(text: isActive ? "running" : "idle", icon: "brain", isActive: isActive)
                }
                Text("feature/dark-ui-retheme")
                    .font(.workspaceMono(.caption))
                    .foregroundStyle(WorkspaceTheme.textLo)
                    .lineLimit(1)
                Text("/Users/dev/work/very-long-project-directory/sources/feature/deeply/nested/module/Implementation/File.swift")
                    .font(.workspaceMono(.caption2))
                    .foregroundStyle(WorkspaceTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .workspaceEmphasis(isActive: isActive)
    }
}

#Preview("Cards and badges · active/inactive, long path") {
    ScrollView {
        VStack(spacing: 12) {
            WorkspaceThemePreviewCard(isActive: true)
                .workspaceCard()
            WorkspaceThemePreviewCard(isActive: false)
                .workspaceCard()
            HStack(spacing: 8) {
                WorkspaceBadge(text: "running", icon: "brain")
                WorkspaceBadge(text: "idle", icon: "brain", isActive: false)
                WorkspaceBadge(text: "connected")
                WorkspaceBadge(text: "offline", isActive: false)
            }
        }
        .padding(WorkspaceTheme.cardPadding)
    }
    .background(WorkspaceTheme.bg.ignoresSafeArea())
}

#Preview("Cards and badges · large Dynamic Type") {
    ScrollView {
        VStack(spacing: 12) {
            WorkspaceThemePreviewCard(isActive: true)
                .workspaceCard()
            WorkspaceThemePreviewCard(isActive: false)
                .workspaceCard()
            HStack(spacing: 8) {
                WorkspaceBadge(text: "running", icon: "brain")
                WorkspaceBadge(text: "idle", icon: "brain", isActive: false)
            }
        }
        .padding(WorkspaceTheme.cardPadding)
    }
    .background(WorkspaceTheme.bg.ignoresSafeArea())
    .environment(\.dynamicTypeSize, .accessibility1)
}
