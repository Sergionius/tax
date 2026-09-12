import SwiftUI

/// Изолированная дизайн-система нетерминальных экранов workspace.
///
/// Всё здесь опционально: экран применяет `.workspaceScreenTheme()` (или отдельные стили)
/// к собственному содержимому. Ничего в этом файле не меняет глобальный `AccentColor`,
/// UIKit appearance-прокси и общую цветовую схему приложения. Тема не должна доставаться
/// терминальному destination: применяйте модификаторы на конкретных экранах, а не на
/// общем `NavigationStack` (см. `workspaceScreenTheme()`).
enum WorkspaceTheme {
    // MARK: - Палитра

    /// Фон экрана.
    static let bg = Color(themeHex: 0x070A1E)
    /// Поверхность карточки.
    static let surface = Color(themeHex: 0x10132C)
    /// Поверхность карточки при нажатии.
    static let surface2 = Color(themeHex: 0x171B3C)
    /// Основная обводка.
    static let border = Color(themeHex: 0x262C52)
    /// Приглушённая обводка.
    static let borderLo = Color(themeHex: 0x1A1E3C)
    /// Основной текст.
    static let textHi = Color(themeHex: 0xF1F2FA)
    /// Вторичный текст.
    static let textLo = Color(themeHex: 0x7B81AC)
    /// Технический/приглушённый текст.
    static let textDim = Color(themeHex: 0x464C78)
    /// Акцент.
    static let accent = Color(themeHex: 0x7278EE)
    /// Приглушённый акцент (неактивные элементы).
    static let accentDim = Color(themeHex: 0x4548A0)
    /// Светлый акцент (текст на акцентном фоне, яркие бейджи).
    static let accentLight = Color(themeHex: 0x9EA3F2)
}

private extension Color {
    /// Цвет из sRGB-триплета, например `0x070A1E`.
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

// MARK: - Типографика

extension Font {
    /// Space Grotesk для интерфейсных текстов; поддерживает Dynamic Type.
    static func workspaceUI(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(Self.spaceGroteskName(for: weight), size: Self.baseSize(for: style), relativeTo: style)
    }

    /// JetBrains Mono для путей, веток, счётчиков и технических данных; поддерживает Dynamic Type.
    static func workspaceMono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(Self.jetBrainsMonoName(for: weight), size: Self.baseSize(for: style), relativeTo: style)
    }

    /// PostScript-имена подключённых начертаний Space Grotesk.
    private static func spaceGroteskName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium: "SpaceGrotesk-Medium"
        case .semibold, .bold, .heavy, .black: "SpaceGrotesk-SemiBold"
        default: "SpaceGrotesk-Regular"
        }
    }

    /// PostScript-имена подключённых начертаний JetBrains Mono.
    private static func jetBrainsMonoName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "JetBrainsMono-Medium"
        default: "JetBrainsMono-Regular"
        }
    }

    /// Базовые размеры системных текстовых стилей для `Font.custom(_:size:relativeTo:)`.
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

// MARK: - Бейдж

/// Небольшой акцентный бейдж: яркий в активном состоянии, приглушённый в неактивном.
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

// MARK: - Карточка

extension WorkspaceTheme {
    /// Радиус скругления карточек.
    static let cardCornerRadius: CGFloat = 14
    /// Толщина обводки карточек.
    static let cardBorderWidth: CGFloat = 1
    /// Внутренние отступы карточек.
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
        // Без теней: карточки отделяются фоном и обводкой.
    }
}

extension View {
    /// Карточка: внутренние отступы 14 pt, фон `surface` (`surface-2` при нажатии),
    /// радиус 14 pt, обводка 1 pt, без теней.
    func workspaceCard(isPressed: Bool = false) -> some View {
        modifier(WorkspaceCardModifier(isPressed: isPressed))
    }
}

// MARK: - Состояние нажатия

/// Нажимаемая карточка: фон `surface`, при нажатии — `surface-2`.
struct WorkspaceCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .workspaceCard(isPressed: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: WorkspaceTheme.cardCornerRadius, style: .continuous))
    }
}

// MARK: - Активность карточек

extension WorkspaceTheme {
    /// Ширина левой полосы активной карточки.
    static let activeBarWidth: CGFloat = 3
    /// Прозрачность неактивных карточек (остаются полностью интерактивными).
    static let inactiveOpacity: Double = 0.55
}

/// Левая полоса 3 pt: яркая акцентная у активных карточек, приглушённая у неактивных.
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
        // Намеренно без .disabled: неактивные элементы остаются доступными для нажатия.
    }
}

extension View {
    /// Приглушает неактивные карточки (≈55% opacity), не превращая их в disabled.
    func workspaceEmphasis(isActive: Bool) -> some View {
        modifier(WorkspaceEmphasisModifier(isActive: isActive))
    }
}

// MARK: - Оформление экрана

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
    /// Применяет тему к одному нетерминальному экрану: акцентный tint, скрытие системного
    /// фона списков (экраны рисуют собственный `bg`), тёмная панель навигации.
    ///
    /// Важно: применяйте модификатор к содержимому конкретного экрана (внутри case
    /// `.navigationDestination` или к корню экрана), а не к общему `NavigationStack` —
    /// иначе tint и оформление панели распространятся на терминальный destination.
    /// Глобальные `AccentColor`, UIKit appearance и цветовая схема приложения не меняются.
    func workspaceScreenTheme() -> some View {
        modifier(WorkspaceScreenThemeModifier())
    }

    /// Локальный заголовок панели навигации в Space Grotesk (toolbar principal),
    /// без изменения UIKit appearance — поэтому оформление не выходит за пределы экрана.
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
}
