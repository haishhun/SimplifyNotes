import Foundation
import PDFKit
import UIKit

nonisolated struct ImportedPDFPage: Sendable, Equatable {
    let index: Int
    let size: CGSize
    let text: String
}

nonisolated struct ImportedPDFInfo: Sendable {
    let fileName: String
    let title: String
    let pages: [ImportedPDFPage]
}

/// Copies PDFs into the app's storage and reads page geometry and text off the main thread.
/// The original document is never modified; annotations live in separate ink files.
nonisolated enum PDFImportService {
    /// Max characters indexed per page for search.
    static let maxIndexedCharacters = 20_000

    @concurrent
    static func importPDF(at url: URL, store: PageContentStoring) async throws -> ImportedPDFInfo {
        let displayName = url.deletingPathExtension().lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AppError.fileAccessDenied(url.lastPathComponent)
        }
        // Validate before copying so a bad file doesn't leave junk behind.
        guard let probe = PDFDocument(url: url) else { throw AppError.unreadablePDF(url.lastPathComponent) }
        if probe.isLocked { throw AppError.encryptedPDF(url.lastPathComponent) }
        guard probe.pageCount > 0 else { throw AppError.emptyPDF(url.lastPathComponent) }

        let fileName = try store.importPDF(from: url)
        let pages = try pageInfo(for: store.pdfURL(named: fileName), name: url.lastPathComponent)
        let title = (probe.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? displayName
        return ImportedPDFInfo(fileName: fileName, title: title, pages: pages)
    }

    /// Imports raw PDF data (e.g. generated from scanned images).
    @concurrent
    static func importPDF(data: Data, title: String, store: PageContentStoring) async throws -> ImportedPDFInfo {
        let temp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileName = try store.importPDF(from: temp)
        let pages = try pageInfo(for: store.pdfURL(named: fileName), name: title)
        return ImportedPDFInfo(fileName: fileName, title: title, pages: pages)
    }

    static func pageInfo(for url: URL, name: String) throws -> [ImportedPDFPage] {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadablePDF(name) }
        var pages: [ImportedPDFPage] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = String((page.string ?? "").prefix(maxIndexedCharacters))
            pages.append(ImportedPDFPage(index: index, size: displaySize(of: page), text: text))
        }
        guard !pages.isEmpty else { throw AppError.emptyPDF(name) }
        return pages
    }

    /// Visible size of a PDF page honouring its /Rotate entry.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        return rotated ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Builds a PDF from scanned or imported images, one image per page.
    static func makePDF(from images: [UIImage]) -> Data {
        let document = PDFDocument()
        for (index, image) in images.enumerated() {
            if let page = PDFPage(image: image) {
                document.insert(page, at: index)
            }
        }
        return document.dataRepresentation() ?? Data()
    }
}
