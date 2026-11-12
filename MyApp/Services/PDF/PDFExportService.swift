import UIKit
import PencilKit

nonisolated enum ExportPaperSize: Hashable, Sendable, Identifiable {
    case original
    case paper(PaperSize)

    var id: String {
        switch self {
        case .original: "original"
        case .paper(let size): size.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .original: "Original Page Size"
        case .paper(let size): size.displayName
        }
    }

    static var allCases: [ExportPaperSize] { [.original] + PaperSize.allCases.map { .paper($0) } }
}

nonisolated enum ExportOrientation: String, CaseIterable, Identifiable, Sendable {
    case automatic, portrait, landscape
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

nonisolated struct PDFExportOptions: Sendable, Equatable {
    var paperSize: ExportPaperSize = .original
    var orientation: ExportOrientation = .automatic
    /// Paper templates (lines, grids, colours). Original PDF content is always kept.
    var includeBackgrounds = true
    var inkScale: CGFloat = 3
    var title = "Notes"

    /// Media box for a page of the given size.
    func mediaSize(for pageSize: CGSize) -> CGSize {
        guard case .paper(let paper) = paperSize else { return pageSize }
        let isLandscape: Bool
        switch orientation {
        case .automatic: isLandscape = pageSize.width > pageSize.height
        case .portrait: isLandscape = false
        case .landscape: isLandscape = true
        }
        return paper.size(for: isLandscape ? .landscape : .portrait)
    }
}

/// One page in an export job. Pages may come from different notebooks.
nonisolated struct ExportPageItem: Sendable, Hashable, Identifiable {
    let id: UUID
    let snapshot: PageRenderSnapshot
    let notebookTitle: String
    let pageNumber: Int

    init(snapshot: PageRenderSnapshot, notebookTitle: String, pageNumber: Int) {
        self.id = UUID()
        self.snapshot = snapshot
        self.notebookTitle = notebookTitle
        self.pageNumber = pageNumber
    }
}

/// Generates combined PDFs in the background. Each page is drawn as:
/// template background (optional) → original PDF page (vector) → images/text → ink.
nonisolated enum PDFExportService {
    @concurrent
    static func export(_ items: [ExportPageItem],
                       options: PDFExportOptions,
                       store: PageContentStoring,
                       to url: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard !items.isEmpty else { throw AppError.nothingToExport }
        // Make sure the editor's pending saves are on disk before reading them.
        store.flush()

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: options.title,
            kCGPDFContextCreator as String: "SimplifyNotes"
        ]
        let firstSize = options.mediaSize(for: items[0].snapshot.size)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize), format: format)
        let includedPages = Set(items.map(\.snapshot.pageID))
        let renderOptions = PageRenderOptions(includeBackground: options.includeBackgrounds,
                                              includePDF: true, inkScale: options.inkScale)
        var cancelled = false

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try renderer.writePDF(to: url) { context in
                for (index, item) in items.enumerated() {
                    if Task.isCancelled { cancelled = true; return }
                    autoreleasepool {
                        let snapshot = item.snapshot
                        let media = CGRect(origin: .zero, size: options.mediaSize(for: snapshot.size))
                        context.beginPage(withBounds: media, pageInfo: [:])
                        let cg = context.cgContext
                        // Named destination so internal links can jump here.
                        UIGraphicsAddPDFContextDestinationAtPoint(snapshot.pageID.uuidString, .zero)

                        let content = store.loadContentSync(pageID: snapshot.pageID)
                        let target = media.aspectFit(snapshot.size)
                        let scale = target.width / max(snapshot.size.width, 1)
                        cg.saveGState()
                        cg.translateBy(x: target.minX, y: target.minY)
                        cg.scaleBy(x: scale, y: scale)
                        PageRenderer.draw(snapshot, content: content, assetURL: store.assetURL(named:),
                                          options: renderOptions, in: cg)
                        cg.restoreGState()

                        // Clickable internal links (only to pages included in this export).
                        for element in content.elements where element.kind == .link {
                            guard let target = element.targetPageID, includedPages.contains(target) else { continue }
                            let r = element.rotatedBounds
                            let linkRect = CGRect(x: media.minX + r.minX * scale + (media.width - snapshot.size.width * scale) / 2,
                                                  y: media.minY + r.minY * scale + (media.height - snapshot.size.height * scale) / 2,
                                                  width: r.width * scale, height: r.height * scale)
                            UIGraphicsSetPDFContextDestinationForRect(target.uuidString, linkRect)
                        }
                    }
                    progress?(Double(index + 1) / Double(items.count))
                }
            }
        } catch {
            throw AppError.exportFailed(error.localizedDescription)
        }
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        return url
    }

    /// A unique, filesystem-safe URL in the temporary exports folder.
    static func temporaryURL(named title: String) -> URL {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "-")
        let name = safe.trimmingCharacters(in: .whitespaces).isEmpty ? "Notes" : safe
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports/\(UUID().uuidString)", directoryHint: .isDirectory)
        return folder.appending(path: "\(name).pdf")
    }
}

/// Parses page ranges such as "1-3, 5, 8-" into zero-based indices (in the order given, without duplicates).
nonisolated enum PageRangeParser {
    enum ParseError: Error, Equatable {
        case invalidToken(String)
        case outOfBounds(Int)
    }

    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        var result: [Int] = []
        var seen = Set<Int>()
        func append(_ index: Int) {
            if seen.insert(index).inserted { result.append(index) }
        }
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        for token in tokens where !token.isEmpty {
            if token.contains("-") {
                let parts = token.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { throw ParseError.invalidToken(token) }
                let start = parts[0].isEmpty ? 1 : Int(parts[0])
                let end = parts[1].isEmpty ? pageCount : Int(parts[1])
                guard let start, let end else { throw ParseError.invalidToken(token) }
                guard start >= 1, start <= pageCount else { throw ParseError.outOfBounds(start) }
                guard end >= 1, end <= pageCount else { throw ParseError.outOfBounds(end) }
                let range = start <= end ? Array(start...end) : Array((end...start).reversed())
                range.forEach { append($0 - 1) }
            } else {
                guard let number = Int(token) else { throw ParseError.invalidToken(token) }
                guard number >= 1, number <= pageCount else { throw ParseError.outOfBounds(number) }
                append(number - 1)
            }
        }
        return result
    }
}
