import SwiftData
import Testing
import Foundation
import PDFKit
import UIKit
@testable import MyApp

@MainActor
@Suite("PDF import & export")
struct PDFTests {
    private func items(_ pages: [Page], notebook: Notebook, store: PageContentStoring) -> [ExportPageItem] {
        pages.map { page in
            ExportPageItem(snapshot: page.renderSnapshot(store: store), notebookTitle: notebook.title,
                           pageNumber: (notebook.sortedPages.firstIndex { $0.id == page.id } ?? 0) + 1)
        }
    }

    private func export(_ items: [ExportPageItem], lib: TestLibrary, options: PDFExportOptions = PDFExportOptions()) async throws -> PDFDocument {
        let url = PDFExportService.temporaryURL(named: "Test")
        _ = try await PDFExportService.export(items, options: options, store: lib.store, to: url)
        return try #require(PDFDocument(url: url))
    }

    private func pageTexts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    private func labelledNotebook(_ lib: TestLibrary, title: String, count: Int) throws -> Notebook {
        let notebook = try lib.repository.createNotebook(title: title, subject: nil, initialPageCount: count)
        for (index, page) in notebook.sortedPages.enumerated() {
            try lib.writeContent(page, label: "\(title)\(index + 1)")
        }
        return notebook
    }

    // MARK: Import

    @Test func importCopiesPDFAndReadsGeometryAndText() async throws {
        let lib = try TestLibrary()
        let source = try TestPDF.write(pages: ["Lecture alpha", "Lecture beta", "Lecture gamma"], size: CGSize(width: 400, height: 600))
        let info = try await PDFImportService.importPDF(at: source, store: lib.store)
        #expect(info.pages.count == 3)
        #expect(info.pages.allSatisfy { $0.size == CGSize(width: 400, height: 600) })
        #expect(info.pages[1].text.contains("beta"))
        // The original is copied, not referenced: deleting the source keeps the notebook working.
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: lib.store.pdfURL(named: info.fileName).path))

        let notebook = try lib.repository.createNotebook(fromPDF: info, subject: nil)
        #expect(notebook.pageCount == 3)
        #expect(notebook.sortedPages.map(\.pdfPageIndex) == [0, 1, 2])
        #expect(notebook.sortedPages.allSatisfy { $0.isPDFBacked && $0.style.template == .blank })
    }

    @Test func importRejectsInvalidFiles() async throws {
        let lib = try TestLibrary()
        let bogus = FileManager.default.temporaryDirectory.appending(path: "bogus-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: bogus)
        await #expect(throws: AppError.self) {
            _ = try await PDFImportService.importPDF(at: bogus, store: lib.store)
        }
    }

    @Test func insertPDFPagesBetweenExistingPages() async throws {
        let lib = try TestLibrary()
        let notebook = try lib.repository.createNotebook(title: "Mixed", subject: nil, initialPageCount: 2)
        let info = try await PDFImportService.importPDF(at: try TestPDF.write(pages: ["S1", "S2"]), store: lib.store)
        try lib.repository.insertPDFPages(info, into: notebook, at: 1)
        let pages = notebook.sortedPages
        #expect(pages.map(\.isPDFBacked) == [false, true, true, false])
        #expect(pages.map(\.sortIndex) == [0, 1, 2, 3])
    }

    // MARK: Export

    @Test func exportWholeNotebookPreservesOrder() async throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, title: "Calc", count: 4)
        let document = try await export(items(notebook.sortedPages, notebook: notebook, store: lib.store), lib: lib)
        #expect(document.pageCount == 4)
        let texts = pageTexts(document)
        for index in 0..<4 { #expect(texts[index].contains("Calc\(index + 1)")) }
    }

    @Test func exportSelectedPagesInCustomOrder() async throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, title: "Bio", count: 5)
        let pages = notebook.sortedPages
        let document = try await export(items([pages[4], pages[0], pages[2]], notebook: notebook, store: lib.store), lib: lib)
        let texts = pageTexts(document)
        #expect(texts.count == 3)
        #expect(texts[0].contains("Bio5"))
        #expect(texts[1].contains("Bio1"))
        #expect(texts[2].contains("Bio3"))
    }

    @Test func exportCombinesMultipleNotebooks() async throws {
        let lib = try TestLibrary()
        let a = try labelledNotebook(lib, title: "Alg", count: 2)
        let b = try labelledNotebook(lib, title: "Geo", count: 3)
        let model = ExportComposerViewModel(items: [], title: "Combined", store: lib.store)
        model.add([a.sortedPages[1]], from: a)
        try model.addRange("3, 1", from: b)
        model.add([a.sortedPages[0]], from: a)
        model.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)   // move "Alg1" first
        let document = try await export(model.queue, lib: lib)
        let texts = pageTexts(document)
        #expect(texts.count == 4)
        #expect(texts[0].contains("Alg1"))
        #expect(texts[1].contains("Alg2"))
        #expect(texts[2].contains("Geo3"))
        #expect(texts[3].contains("Geo1"))
    }

    @Test func exportKeepsOriginalPDFContentAndAnnotations() async throws {
        let lib = try TestLibrary()
        let info = try await PDFImportService.importPDF(at: try TestPDF.write(pages: ["Original theorem"]), store: lib.store)
        let notebook = try lib.repository.createNotebook(fromPDF: info, subject: nil)
        let page = notebook.sortedPages[0]
        try lib.writeContent(page, label: "My annotation")
        // Backgrounds off must still keep the original PDF.
        var options = PDFExportOptions()
        options.includeBackgrounds = false
        let document = try await export(items([page], notebook: notebook, store: lib.store), lib: lib, options: options)
        let text = pageTexts(document)[0]
        #expect(text.contains("Original theorem"))
        #expect(text.contains("My annotation"))
    }

    @Test func exportUsesChosenPaperSizeAndOrientation() async throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, title: "Size", count: 1)
        let pageItems = items(notebook.sortedPages, notebook: notebook, store: lib.store)

        let original = try await export(pageItems, lib: lib)
        #expect(original.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))

        var options = PDFExportOptions()
        options.paperSize = .paper(.a4)
        options.orientation = .landscape
        let a4 = try await export(pageItems, lib: lib, options: options)
        let size = try #require(a4.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(abs(size.width - 841.89) < 1)
        #expect(abs(size.height - 595.28) < 1)
    }

    @Test func exportOfNothingThrows() async throws {
        let lib = try TestLibrary()
        await #expect(throws: AppError.nothingToExport) {
            _ = try await PDFExportService.export([], options: PDFExportOptions(), store: lib.store,
                                                  to: PDFExportService.temporaryURL(named: "x"))
        }
    }

    @Test func exportReflectsPagesDeletedAfterQueueing() async throws {
        // A page deleted after being queued exports as an empty page instead of crashing.
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, title: "Gone", count: 2)
        let queued = items(notebook.sortedPages, notebook: notebook, store: lib.store)
        try lib.repository.deletePages([notebook.sortedPages[0]])
        let document = try await export(queued, lib: lib)
        #expect(document.pageCount == 2)
        #expect(pageTexts(document)[1].contains("Gone2"))
    }

    @Test func temporaryURLSanitizesNames() {
        let url = PDFExportService.temporaryURL(named: "Week 3/4: Notes?")
        #expect(url.lastPathComponent == "Week 3-4- Notes-.pdf")
        #expect(PDFExportService.temporaryURL(named: "   ").lastPathComponent == "Notes.pdf")
    }

    // MARK: Page ranges

    @Test func rangeParserHandlesListsRangesAndOpenEnds() throws {
        #expect(try PageRangeParser.parse("1-3, 5", pageCount: 10) == [0, 1, 2, 4])
        #expect(try PageRangeParser.parse("8-", pageCount: 10) == [7, 8, 9])
        #expect(try PageRangeParser.parse("-2", pageCount: 10) == [0, 1])
        #expect(try PageRangeParser.parse("3-1", pageCount: 10) == [2, 1, 0])
        #expect(try PageRangeParser.parse("2, 2, 1-2", pageCount: 10) == [1, 0], "Duplicates are removed")
        #expect(try PageRangeParser.parse("", pageCount: 10).isEmpty)
    }

    @Test func rangeParserRejectsBadInput() {
        #expect(throws: PageRangeParser.ParseError.outOfBounds(11)) { try PageRangeParser.parse("11", pageCount: 10) }
        #expect(throws: PageRangeParser.ParseError.outOfBounds(0)) { try PageRangeParser.parse("0-2", pageCount: 10) }
        #expect(throws: PageRangeParser.ParseError.invalidToken("a")) { try PageRangeParser.parse("a", pageCount: 10) }
        #expect(throws: PageRangeParser.ParseError.invalidToken("1-2-3")) { try PageRangeParser.parse("1-2-3", pageCount: 10) }
    }
}
