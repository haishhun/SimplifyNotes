import SwiftUI

/// Design tokens: spacing, radii, shadows, typography and colours.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 12
        static let l: CGFloat = 18
        static let xl: CGFloat = 26
    }

    enum Colors {
        /// The "desk" behind pages in the editor.
        static let canvasBackdrop = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        })
        static let surface = Color(uiColor: .secondarySystemGroupedBackground)
        static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        static let hairline = Color.primary.opacity(0.08)
        static let accent = Color.accentColor
        static let subjectChoices = ["#4C6EF5", "#228BE6", "#15AABF", "#12B886", "#40C057", "#FAB005",
                                     "#FD7E14", "#FA5252", "#E64980", "#BE4BDB", "#7950F2", "#495057"]
    }

    enum Motion {
        static let standard = Animation.snappy(duration: 0.25)
        static let gentle = Animation.smooth(duration: 0.35)
    }

    static let subjectSymbols = ["book.closed", "function", "atom", "flask", "leaf", "globe.europe.africa",
                                 "chart.line.uptrend.xyaxis", "cpu", "building.columns", "music.note",
                                 "paintpalette", "brain.head.profile", "hammer", "text.book.closed"]
}

struct CardModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.m
    func body(content: Content) -> some View {
        content
            .background(Theme.Colors.surface, in: .rect(cornerRadius: radius))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

extension View {
    func cardStyle(radius: CGFloat = Theme.Radius.m) -> some View {
        modifier(CardModifier(radius: radius))
    }

    /// Floating, translucent chrome used by the editor's toolbars.
    func floatingChrome(radius: CGFloat = Theme.Radius.l) -> some View {
        self
            .background(.regularMaterial, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.Colors.hairline))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

/// Square icon button used in floating toolbars.
struct ToolbarIconButton: View {
    let systemName: String
    let label: String
    var isSelected = false
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(isSelected ? Color.white : tint)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Theme.Radius.s + 2).fill(Color.accentColor)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ColorSwatch: View {
    let hex: String
    var isSelected = false
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

/// Live preview of a paper template drawn with the same renderer as the editor.
struct PaperPreview: View {
    let style: PageStyle
    var aspect: CGSize? = nil

    var body: some View {
        let pageSize = aspect ?? style.pageSize
        Canvas { context, size in
            context.withCGContext { cg in
                let scale = size.width / pageSize.width
                cg.scaleBy(x: scale, y: scale)
                cg.clip(to: CGRect(origin: .zero, size: pageSize))
                PageBackgroundRenderer.draw(style, size: pageSize, in: cg)
            }
        }
        .aspectRatio(pageSize.width / pageSize.height, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Colors.hairline))
    }
}
