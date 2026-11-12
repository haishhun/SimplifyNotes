import SwiftData
import Testing
import Foundation
@testable import MyApp

@MainActor
@Suite("Subjects & notebooks")
struct NotebookManagementTests {
    @Test func createSubjectTrimsAndFallsBack() throws {
        let lib = try TestLibrary()
        let named = try lib.repository.createSubject(name: "  Calculus  ")
        let unnamed = try lib.repository.createSubject(name: "   ")
        #expect(named.name == "Calculus")
        #expect(unnamed.name == "Untitled Subject")
        #expect(unnamed.sortIndex == named.sortIndex + 1)
        #expect(try lib.repository.fetchSubjects().map(\.name) == ["Calculus", "Untitled Subject"])
    }

    @Test func createNotebookHasOneStyledPage() throws {
        let lib = try TestLibrary()
        let subject = try lib.repository.createSubject(name: "Physics")
        let style = PageStyle(template: .grid, paperSize: .a4, orientation: .landscape)
        let notebook = try lib.repository.createNotebook(title: "Mechanics", subject: subject, style: style)
        #expect(notebook.pageCount == 1)
        let page = try #require(notebook.sortedPages.first)
        #expect(page.style.template == .grid)
        #expect(page.width > page.height, "Landscape A4 must be wider than tall")
        #expect(subject.notebooks?.count == 1)
    }

    @Test func renameFavoriteAndMove() throws {
        let lib = try TestLibrary()
        let a = try lib.repository.createSubject(name: "A")
        let b = try lib.repository.createSubject(name: "B")
        let notebook = try lib.repository.createNotebook(title: "Notes", subject: a)
        try lib.repository.renameNotebook(notebook, to: "Lecture 1")
        try lib.repository.renameNotebook(notebook, to: "  ")
        #expect(notebook.title == "Lecture 1", "Blank rename keeps the previous title")
        try lib.repository.setFavorite(notebook, true)
        #expect(notebook.isFavorite)
        try lib.repository.moveNotebook(notebook, to: b)
        #expect(notebook.subject?.id == b.id)
        #expect(a.notebooks?.isEmpty == true)
        try lib.repository.moveNotebook(notebook, to: nil)
        #expect(notebook.subject == nil)
    }

    @Test func deleteNotebookRemovesFilesAndPDF() async throws {
        let lib = try TestLibrary()
        let url = try TestPDF.write(pages: ["One", "Two"])
        let info = try await PDFImportService.importPDF(at: url, store: lib.store)
        let notebook = try lib.repository.createNotebook(fromPDF: info, subject: nil)
        let pages = notebook.sortedPages
        for page in pages { try lib.writeContent(page, label: "x") }
        #expect(pages.allSatisfy { lib.pageDirectoryExists($0.id) })
        #expect(FileManager.default.fileExists(atPath: lib.store.pdfURL(named: info.fileName).path))

        try lib.repository.deleteNotebook(notebook)
        #expect(try lib.repository.fetchNotebooks().isEmpty)
        #expect(pages.allSatisfy { !lib.pageDirectoryExists($0.id) })
        #expect(!FileManager.default.fileExists(atPath: lib.store.pdfURL(named: info.fileName).path))
    }

    @Test func deleteSubjectCascadesToNotebooksAndPages() throws {
        let lib = try TestLibrary()
        let subject = try lib.repository.createSubject(name: "Chemistry")
        let n1 = try lib.repository.createNotebook(title: "Organic", subject: subject, initialPageCount: 3)
        _ = try lib.repository.createNotebook(title: "Inorganic", subject: subject)
        let pageIDs = n1.sortedPages.map(\.id)
        for page in n1.sortedPages { try lib.writeContent(page, label: "c") }

        try lib.repository.deleteSubject(subject)
        #expect(try lib.repository.fetchSubjects().isEmpty)
        #expect(try lib.repository.fetchNotebooks().isEmpty)
        #expect(try lib.container.mainContext.fetchCount(FetchDescriptor<Page>()) == 0)
        #expect(pageIDs.allSatisfy { !lib.pageDirectoryExists($0) })
    }

    @Test func duplicateNotebookCopiesContentIndependently() throws {
        let lib = try TestLibrary()
        let notebook = try lib.repository.createNotebook(title: "Algebra", subject: nil, initialPageCount: 2)
        let originals = notebook.sortedPages
        try lib.writeContent(originals[0], label: "first")
        try lib.writeContent(originals[1], label: "second")

        let copy = try lib.repository.duplicateNotebook(notebook)
        lib.store.flush()
        let copies = copy.sortedPages
        #expect(copy.title == "Algebra Copy")
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).isDisjoint(with: originals.map(\.id)))
        #expect(lib.label(of: copies[0]) == "first")
        #expect(lib.label(of: copies[1]) == "second")

        // Deleting the copy must not affect the original.
        try lib.repository.deleteNotebook(copy)
        #expect(lib.label(of: originals[0]) == "first")
    }

    @Test func searchFindsTitlesAndPageText() throws {
        let lib = try TestLibrary()
        let notebook = try lib.repository.createNotebook(title: "Thermodynamics", subject: nil, initialPageCount: 2)
        let page = notebook.sortedPages[1]
        lib.repository.updateRecognizedText(page, text: "entropy always increases", version: page.contentVersion)
        let service = SearchService(context: lib.container.mainContext)
        #expect(service.search("thermo").contains { $0.kind == .notebook })
        let pageHit = try #require(service.search("ENTROPY").first { $0.kind == .page })
        #expect(pageHit.pageNumber == 2)
        #expect(pageHit.snippet.contains("entropy"))
        #expect(service.search("   ").isEmpty)
    }
}
