import PencilKit
import SwiftData
import Testing
import Foundation
@testable import MyApp

@MainActor
@Suite("Page operations")
struct PageOperationsTests {
    /// Notebook with pages labelled "P1"…"Pn".
    private func labelledNotebook(_ lib: TestLibrary, count: Int, title: String = "Book") throws -> Notebook {
        let notebook = try lib.repository.createNotebook(title: title, subject: nil, initialPageCount: count)
        for (index, page) in notebook.sortedPages.enumerated() {
            page.title = "P\(index + 1)"
            try lib.writeContent(page, label: "\(title)-P\(index + 1)")
        }
        try lib.repository.save()
        return notebook
    }

    private func titles(_ notebook: Notebook) -> [String] { notebook.sortedPages.map(\.title) }

    private func expectContiguous(_ notebook: Notebook) {
        #expect(notebook.sortedPages.map(\.sortIndex) == Array(0..<notebook.pageCount))
    }

    @Test func addPageAtStartMiddleEndAndOutOfRange() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 2)
        try lib.repository.addPage(to: notebook, at: 0).title = "start"
        try lib.repository.addPage(to: notebook, at: 2).title = "middle"
        try lib.repository.addPage(to: notebook).title = "end"
        try lib.repository.addPage(to: notebook, at: 99).title = "clamped"
        try lib.repository.addPage(to: notebook, at: -5).title = "negative"
        #expect(titles(notebook) == ["negative", "start", "P1", "middle", "P2", "end", "clamped"])
        expectContiguous(notebook)
    }

    @Test func newPageUsesNotebookDefaultStyle() throws {
        let lib = try TestLibrary()
        let notebook = try lib.repository.createNotebook(title: "Music", subject: nil, style: PageStyle(template: .music))
        let page = try lib.repository.addPage(to: notebook)
        #expect(page.style.template == .music)
    }

    @Test func deleteMiddleFirstLastAndAll() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 5)
        let pages = notebook.sortedPages
        try lib.repository.deletePages([pages[2]])
        #expect(titles(notebook) == ["P1", "P2", "P4", "P5"])
        expectContiguous(notebook)
        #expect(!lib.pageDirectoryExists(pages[2].id))

        try lib.repository.deletePages([pages[0], pages[4]])
        #expect(titles(notebook) == ["P2", "P4"])
        expectContiguous(notebook)

        try lib.repository.deletePages(notebook.sortedPages)
        #expect(notebook.pageCount == 0)
        try lib.repository.deletePages([])   // no-op must not throw
    }

    @Test func deletingDuplicateOfPDFPageKeepsSharedPDF() async throws {
        let lib = try TestLibrary()
        let info = try await PDFImportService.importPDF(at: try TestPDF.write(pages: ["A"]), store: lib.store)
        let notebook = try lib.repository.createNotebook(fromPDF: info, subject: nil)
        let original = try #require(notebook.sortedPages.first)
        let copy = try #require(try lib.repository.duplicatePages([original]).first)
        try lib.repository.deletePages([original])
        #expect(FileManager.default.fileExists(atPath: lib.store.pdfURL(named: info.fileName).path),
                "PDF is still used by the duplicate")
        try lib.repository.deletePages([copy])
        #expect(!FileManager.default.fileExists(atPath: lib.store.pdfURL(named: info.fileName).path))
    }

    @Test func duplicateInsertsCopiesAfterLastSelectedWithContent() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 4)
        let pages = notebook.sortedPages
        let copies = try lib.repository.duplicatePages([pages[2], pages[0]])
        lib.store.flush()
        #expect(titles(notebook) == ["P1", "P2", "P3", "P1", "P3", "P4"])
        expectContiguous(notebook)
        #expect(copies.map { lib.label(of: $0) } == ["Book-P1", "Book-P3"])
        #expect(Set(copies.map(\.id)).isDisjoint(with: pages.map(\.id)))
    }

    @Test func duplicatedContentIsIndependent() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 1)
        let original = notebook.sortedPages[0]
        let copy = try #require(try lib.repository.duplicatePages([original]).first)
        lib.store.save(elements: [], pageID: copy.id)
        lib.store.flush()
        #expect(lib.label(of: original) == "Book-P1")
        #expect(lib.label(of: copy) == nil)
    }

    @Test func reorderBeforeTargetAndToEnd() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 5)
        let p = notebook.sortedPages
        try lib.repository.reorder([p[3], p[4]], in: notebook, before: p[1])
        #expect(titles(notebook) == ["P1", "P4", "P5", "P2", "P3"])
        try lib.repository.reorder([p[0]], in: notebook, before: nil)
        #expect(titles(notebook) == ["P4", "P5", "P2", "P3", "P1"])
        // Moving a page before itself is a no-op.
        try lib.repository.reorder([p[1]], in: notebook, before: p[1])
        expectContiguous(notebook)
        #expect(notebook.pageCount == 5)
    }

    @Test func moveFromOffsetsMatchesListSemantics() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 5)
        try lib.repository.movePages(in: notebook, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(titles(notebook) == ["P2", "P3", "P1", "P4", "P5"])
        try lib.repository.movePages(in: notebook, fromOffsets: IndexSet([3, 4]), toOffset: 0)
        #expect(titles(notebook) == ["P4", "P5", "P2", "P3", "P1"])
        try lib.repository.movePages(in: notebook, fromOffsets: IndexSet(integer: 1), toOffset: 5)
        #expect(titles(notebook) == ["P4", "P2", "P3", "P1", "P5"])
        expectContiguous(notebook)
    }

    @Test func movePagesBetweenNotebooks() throws {
        let lib = try TestLibrary()
        let source = try labelledNotebook(lib, count: 4, title: "S")
        let destination = try labelledNotebook(lib, count: 2, title: "D")
        let moving = [source.sortedPages[3], source.sortedPages[1]]
        try lib.repository.movePages(moving, to: destination, at: 1)
        #expect(titles(source) == ["P1", "P3"])
        #expect(titles(destination) == ["P1", "P2", "P4", "P2"])
        expectContiguous(source)
        expectContiguous(destination)
        // Content follows the page (files are keyed by page id).
        #expect(lib.label(of: destination.sortedPages[1]) == "S-P2")
        #expect(moving.allSatisfy { $0.notebook?.id == destination.id })
    }

    @Test func moveIntoSameNotebookDoesNotDuplicate() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 3)
        try lib.repository.movePages([notebook.sortedPages[0]], to: notebook)
        #expect(titles(notebook) == ["P2", "P3", "P1"])
        expectContiguous(notebook)
    }

    @Test func copyPasteAcrossNotebooksCreatesIndependentPages() throws {
        let lib = try TestLibrary()
        let source = try labelledNotebook(lib, count: 3, title: "S")
        let destination = try labelledNotebook(lib, count: 1, title: "D")
        let clipboard = lib.repository.snapshot(of: [source.sortedPages[2], source.sortedPages[0]])
        #expect(clipboard.map(\.title) == ["P1", "P3"], "Snapshots are in page order")
        let pasted = try lib.repository.paste(clipboard, into: destination, at: 0)
        #expect(titles(destination) == ["P1", "P3", "P1"])
        #expect(pasted.map { lib.label(of: $0) } == ["S-P1", "S-P3"])
        // Deleting the source must not affect pasted pages.
        try lib.repository.deleteNotebook(source)
        #expect(lib.label(of: pasted[0]) == "S-P1")
        #expect(pasted[0].contentVersion == 0 || pasted[0].elementsText == "S-P1")
    }

    @Test func changingTemplateKeepsInk() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 1)
        let page = notebook.sortedPages[0]
        let before = lib.store.loadContentSync(pageID: page.id)
        let version = page.contentVersion
        try lib.repository.applyStyle(PageStyle(template: .dotted, paperSize: .a5, orientation: .landscape), to: [page])
        let after = lib.store.loadContentSync(pageID: page.id)
        #expect(page.style.template == .dotted)
        #expect(abs(page.width - Double(PaperSize.a5.size(for: .landscape).width)) < 0.001)
        #expect(after.drawing.strokes.count == before.drawing.strokes.count)
        #expect(after.elements == before.elements)
        #expect(page.contentVersion == version + 1, "Thumbnails are invalidated")
    }

    @Test func templateChangeKeepsPDFPageSize() async throws {
        let lib = try TestLibrary()
        let info = try await PDFImportService.importPDF(at: try TestPDF.write(pages: ["X"], size: CGSize(width: 300, height: 500)), store: lib.store)
        let notebook = try lib.repository.createNotebook(fromPDF: info, subject: nil)
        let page = notebook.sortedPages[0]
        try lib.repository.applyStyle(PageStyle(template: .grid, paperSize: .legal), to: [page])
        #expect(page.size == CGSize(width: 300, height: 500))
    }

    @Test func renameAndBookmark() throws {
        let lib = try TestLibrary()
        let notebook = try labelledNotebook(lib, count: 2)
        let page = notebook.sortedPages[1]
        try lib.repository.renamePage(page, to: "  Derivatives ")
        #expect(page.title == "Derivatives")
        #expect(page.displayTitle(index: 1) == "Derivatives")
        try lib.repository.renamePage(page, to: "")
        #expect(page.displayTitle(index: 1) == "Page 2")
        try lib.repository.setBookmarked([page], true)
        #expect(notebook.sortedPages.filter(\.isBookmarked).count == 1)
    }
}
