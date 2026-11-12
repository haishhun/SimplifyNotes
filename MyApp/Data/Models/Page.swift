import Foundation
import SwiftData
import CoreGraphics

/// Page metadata. Ink and page elements live in files managed by
/// `PageContentStoring`, keyed by `id`, so the database stays small.
@Model
final class Page {
    var id: UUID = UUID()
    var notebook: Notebook?
    var sortIndex: Int = 0
    var title: String = ""
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now

    var width: Double = 612
    var height: Double = 792

    // Background style (stored as flat attributes so they're queryable and CloudKit-friendly).
    var templateRaw: String = PaperTemplate.collegeRuled.rawValue
    var paperSizeRaw: String = PaperSize.letter.rawValue
    var orientationRaw: String = PaperOrientation.portrait.rawValue
    var backgroundColorHex: String = "#FFFFFF"
    var lineColorHex: String = "#B9C8DC"
    var spacing: Double = 20.4
    var marginTop: Double = 72
    var marginLeft: Double = 72

    /// When set, the page is backed by a page of an imported PDF document.
    var pdfFileName: String?
    var pdfPageIndex: Int = 0

    var isBookmarked: Bool = false

    // Search indexes
    var recognizedText: String = ""
    var elementsText: String = ""
    var pdfText: String = ""

    /// Incremented every time ink or elements are saved. Drives thumbnail invalidation.
    var contentVersion: Int = 0
    /// `contentVersion` the handwriting index was computed for.
    var recognizedVersion: Int = -1

    init(style: PageStyle, sortIndex: Int, size: CGSize? = nil) {
        self.id = UUID()
        self.sortIndex = sortIndex
        self.createdAt = .now
        self.modifiedAt = .now
        self.style = style
        let pageSize = size ?? style.pageSize
        self.width = pageSize.width
        self.height = pageSize.height
    }

    var style: PageStyle {
        get {
            PageStyle(template: PaperTemplate(rawValue: templateRaw) ?? .blank,
                      paperSize: PaperSize(rawValue: paperSizeRaw) ?? .letter,
                      orientation: PaperOrientation(rawValue: orientationRaw) ?? .portrait,
                      backgroundColorHex: backgroundColorHex,
                      lineColorHex: lineColorHex,
                      spacing: spacing,
                      marginTop: marginTop,
                      marginLeft: marginLeft)
        }
        set {
            templateRaw = newValue.template.rawValue
            paperSizeRaw = newValue.paperSize.rawValue
            orientationRaw = newValue.orientation.rawValue
            backgroundColorHex = newValue.backgroundColorHex
            lineColorHex = newValue.lineColorHex
            spacing = newValue.spacing
            marginTop = newValue.marginTop
            marginLeft = newValue.marginLeft
        }
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var isPDFBacked: Bool { pdfFileName != nil }

    /// "Page 3" or the custom title.
    func displayTitle(index: Int) -> String {
        title.isEmpty ? "Page \(index + 1)" : title
    }

    func markContentChanged() {
        contentVersion += 1
        modifiedAt = .now
    }
}
