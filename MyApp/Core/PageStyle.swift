import Foundation
import CoreGraphics

/// The ruling pattern printed on a page.
nonisolated enum PaperTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case blank
    case collegeRuled
    case wideRuled
    case grid
    case dotted
    case cornell
    case graph
    case music

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blank: "Blank"
        case .collegeRuled: "College Ruled"
        case .wideRuled: "Wide Ruled"
        case .grid: "Grid"
        case .dotted: "Dotted"
        case .cornell: "Cornell"
        case .graph: "Graph"
        case .music: "Music"
        }
    }

    var symbolName: String {
        switch self {
        case .blank: "doc"
        case .collegeRuled: "line.3.horizontal"
        case .wideRuled: "equal"
        case .grid: "squareshape.split.3x3"
        case .dotted: "circle.grid.3x3"
        case .cornell: "rectangle.split.2x1"
        case .graph: "grid"
        case .music: "music.note.list"
        }
    }

    /// Default spacing in points (1 pt = 1/72 inch).
    var defaultSpacing: Double {
        switch self {
        case .blank: 20
        case .collegeRuled: 20.4   // 7.1 mm
        case .wideRuled: 24.7      // 8.7 mm
        case .grid: 20
        case .dotted: 18
        case .cornell: 20.4
        case .graph: 14.17         // 5 mm minor grid
        case .music: 6             // gap between staff lines
        }
    }

    /// Whether the template uses a vertical margin line.
    var supportsMarginLine: Bool {
        self == .collegeRuled || self == .wideRuled
    }
}

nonisolated enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case letter, a4, a5, b5, legal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .letter: "US Letter"
        case .a4: "A4"
        case .a5: "A5"
        case .b5: "B5"
        case .legal: "US Legal"
        }
    }

    /// Portrait size in PDF points.
    var portraitSize: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .b5: CGSize(width: 498.9, height: 708.66)
        case .legal: CGSize(width: 612, height: 1008)
        }
    }

    func size(for orientation: PaperOrientation) -> CGSize {
        let size = portraitSize
        return orientation == .portrait ? size : CGSize(width: size.height, height: size.width)
    }
}

nonisolated enum PaperOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait, landscape
    var id: String { rawValue }
    var displayName: String { self == .portrait ? "Portrait" : "Landscape" }
}

/// All visual parameters for a page background. Pure value type so it can be
/// handed to background renderers safely.
nonisolated struct PageStyle: Codable, Hashable, Sendable {
    var template: PaperTemplate = .collegeRuled
    var paperSize: PaperSize = .letter
    var orientation: PaperOrientation = .portrait
    var backgroundColorHex: String = "#FFFFFF"
    var lineColorHex: String = "#B9C8DC"
    var spacing: Double = PaperTemplate.collegeRuled.defaultSpacing
    var marginTop: Double = 72
    var marginLeft: Double = 72

    init() {}

    init(template: PaperTemplate,
         paperSize: PaperSize = .letter,
         orientation: PaperOrientation = .portrait,
         backgroundColorHex: String = "#FFFFFF",
         lineColorHex: String = "#B9C8DC",
         spacing: Double? = nil,
         marginTop: Double = 72,
         marginLeft: Double = 72) {
        self.template = template
        self.paperSize = paperSize
        self.orientation = orientation
        self.backgroundColorHex = backgroundColorHex
        self.lineColorHex = lineColorHex
        self.spacing = spacing ?? template.defaultSpacing
        self.marginTop = marginTop
        self.marginLeft = marginLeft
    }

    var pageSize: CGSize { paperSize.size(for: orientation) }

    // Tolerant decoding so older files keep loading when new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PageStyle()
        template = (try? c.decode(PaperTemplate.self, forKey: .template)) ?? defaults.template
        paperSize = (try? c.decode(PaperSize.self, forKey: .paperSize)) ?? defaults.paperSize
        orientation = (try? c.decode(PaperOrientation.self, forKey: .orientation)) ?? defaults.orientation
        backgroundColorHex = (try? c.decode(String.self, forKey: .backgroundColorHex)) ?? defaults.backgroundColorHex
        lineColorHex = (try? c.decode(String.self, forKey: .lineColorHex)) ?? defaults.lineColorHex
        spacing = (try? c.decode(Double.self, forKey: .spacing)) ?? template.defaultSpacing
        marginTop = (try? c.decode(Double.self, forKey: .marginTop)) ?? defaults.marginTop
        marginLeft = (try? c.decode(Double.self, forKey: .marginLeft)) ?? defaults.marginLeft
    }

    static let `default` = PageStyle()

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Hash that is stable across launches (Swift's `hashValue` is randomly seeded),
    /// used in on-disk cache keys.
    var stableHash: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in encoded() {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    static func decode(_ data: Data?) -> PageStyle? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(PageStyle.self, from: data)
    }
}
