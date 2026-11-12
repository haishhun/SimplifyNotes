import os
import Foundation
import SwiftData
import CoreGraphics

/// A self-contained copy of a page used for copy & paste (works across notebooks).
struct PageSnapshot {
    var title: String
    var style: PageStyle
    var size: CGSize
    var pdfFileName: String?
    var pdfPageIndex: Int
    var pdfText: String
    var recognizedText: String
    var elementsText: String
    var content: PageContent
}

/// Business logic for subjects, notebooks and pages. Every mutating call saves
/// the context immediately so metadata and files never drift apart after a crash.
@MainActor
final class LibraryRepository {
    let context: ModelContext
    let store: PageContentStoring

    init(context: ModelContext, store: PageContentStoring) {
        self.context = context
        self.store = store
    }

    func save() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Log.storage.error("Context save failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: Subjects

    func fetchSubjects() throws -> [Subject] {
        try context.fetch(FetchDescriptor<Subject>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]))
    }

    @discardableResult
    func createSubject(name: String, colorHex: String = "#4C6EF5", symbolName: String = "book.closed") throws -> Subject {
        let nextIndex = ((try? fetchSubjects())?.map(\.sortIndex).max() ?? -1) + 1
        let subject = Subject(name: Self.cleanName(name, fallback: "Untitled Subject"), colorHex: colorHex,
                              symbolName: symbolName, sortIndex: nextIndex)
        context.insert(subject)
        try save()
        return subject
    }

    func updateSubject(_ subject: Subject, name: String, colorHex: String, symbolName: String) throws {
        subject.name = Self.cleanName(name, fallback: subject.name)
        subject.colorHex = colorHex
        subject.symbolName = symbolName
        try save()
    }

    func deleteSubject(_ subject: Subject) throws {
        let notebooks = subject.notebooks ?? []
        let cleanup = collectFiles(for: notebooks)
        context.delete(subject)
        try save()
        purge(cleanup)
    }

    // MARK: Notebooks

    func fetchNotebooks() throws -> [Notebook] {
        try context.fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))
    }

    @discardableResult
    func createNotebook(title: String, subject: Subject?, coverColorHex: String = "#3B5BDB",
                        style: PageStyle = .default, initialPageCount: Int = 1) throws -> Notebook {
        let notebook = Notebook(title: Self.cleanName(title, fallback: "Untitled Notebook"), subject: subject,
                                coverColorHex: coverColorHex, defaultStyle: style)
        context.insert(notebook)
        for index in 0..<max(0, initialPageCount) {
            let page = Page(style: style, sortIndex: index)
            page.notebook = notebook
            context.insert(page)
        }
        try save()
        return notebook
    }

    func renameNotebook(_ notebook: Notebook, to title: String) throws {
        notebook.title = Self.cleanName(title, fallback: notebook.title)
        notebook.touch()
        try save()
    }

    func setFavorite(_ notebook: Notebook, _ isFavorite: Bool) throws {
        notebook.isFavorite = isFavorite
        try save()
    }

    func moveNotebook(_ notebook: Notebook, to subject: Subject?) throws {
        notebook.subject = subject
        try save()
    }

    func updateNotebookAppearance(_ notebook: Notebook, coverColorHex: String) throws {
        notebook.coverColorHex = coverColorHex
        try save()
    }

    func markOpened(_ notebook: Notebook) {
        notebook.lastOpenedAt = .now
        try? save()
    }

    func deleteNotebook(_ notebook: Notebook) throws {
        let cleanup = collectFiles(for: [notebook])
        context.delete(notebook)
        try save()
        purge(cleanup)
    }

    @discardableResult
    func duplicateNotebook(_ notebook: Notebook) throws -> Notebook {
        let copy = Notebook(title: notebook.title + " Copy", subject: notebook.subject,
                            coverColorHex: notebook.coverColorHex, defaultStyle: notebook.defaultStyle)
        context.insert(copy)
        for page in notebook.sortedPages {
            let newPage = clonePageMetadata(page, sortIndex: page.sortIndex)
            newPage.notebook = copy
            context.insert(newPage)
            store.duplicateContent(from: page.id, to: newPage.id)
        }
        try save()
        return copy
    }

    // MARK: Pages — creation

    /// Inserts a blank page. `index` is the position in display order (nil = end).
    @discardableResult
    func addPage(to notebook: Notebook, at index: Int? = nil, style: PageStyle? = nil) throws -> Page {
        var pages = notebook.sortedPages
        let resolvedStyle = style ?? notebook.defaultStyle
        let page = Page(style: resolvedStyle, sortIndex: 0)
        page.notebook = notebook
        context.insert(page)
        let insertAt = min(max(index ?? pages.count, 0), pages.count)
        pages.insert(page, at: insertAt)
        renumber(pages)
        notebook.touch()
        try save()
        return page
    }

    /// Adds pages backed by an imported PDF document.
    @discardableResult
    func insertPDFPages(_ info: ImportedPDFInfo, into notebook: Notebook, at index: Int? = nil) throws -> [Page] {
        var pages = notebook.sortedPages
        let insertAt = min(max(index ?? pages.count, 0), pages.count)
        var newPages: [Page] = []
        var style = notebook.defaultStyle
        style.template = .blank
        for pdfPage in info.pages {
            let page = Page(style: style, sortIndex: 0, size: pdfPage.size)
            page.pdfFileName = info.fileName
            page.pdfPageIndex = pdfPage.index
            page.pdfText = pdfPage.text
            page.notebook = notebook
            context.insert(page)
            newPages.append(page)
        }
        pages.insert(contentsOf: newPages, at: insertAt)
        renumber(pages)
        notebook.touch()
        try save()
        return newPages
    }

    @discardableResult
    func createNotebook(fromPDF info: ImportedPDFInfo, subject: Subject?) throws -> Notebook {
        let notebook = try createNotebook(title: info.title, subject: subject, coverColorHex: "#495057",
                                          style: PageStyle(template: .blank), initialPageCount: 0)
        try insertPDFPages(info, into: notebook)
        return notebook
    }

    // MARK: Pages — editing

    func renamePage(_ page: Page, to title: String) throws {
        page.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        page.modifiedAt = .now
        try save()
    }

    func setBookmarked(_ pages: [Page], _ bookmarked: Bool) throws {
        pages.forEach { $0.isBookmarked = bookmarked }
        try save()
    }

    /// Changes the background without touching ink or elements.
    /// PDF-backed pages keep their size; template pages adopt the new paper size.
    func applyStyle(_ style: PageStyle, to pages: [Page]) throws {
        for page in pages {
            page.style = style
            if !page.isPDFBacked {
                page.width = style.pageSize.width
                page.height = style.pageSize.height
            }
            page.markContentChanged()
        }
        pages.first?.notebook?.touch()
        try save()
    }

    // MARK: Pages — structure

    func deletePages(_ pagesToDelete: [Page]) throws {
        guard !pagesToDelete.isEmpty else { return }
        let ids = Set(pagesToDelete.map(\.id))
        let notebooks = Set(pagesToDelete.compactMap(\.notebook).map(\.persistentModelID))
        let pdfNames = Set(pagesToDelete.compactMap(\.pdfFileName))
        let affected = pagesToDelete.compactMap(\.notebook)
        for page in pagesToDelete { context.delete(page) }
        for notebook in affected where notebooks.contains(notebook.persistentModelID) {
            renumber(notebook.sortedPages.filter { !ids.contains($0.id) })
            notebook.touch()
        }
        try save()
        store.deleteContent(pageIDs: Array(ids))
        deleteUnreferencedPDFs(pdfNames)
    }

    /// Duplicates each page and inserts the copy right after the last selected page.
    @discardableResult
    func duplicatePages(_ selection: [Page]) throws -> [Page] {
        guard let notebook = selection.first?.notebook else { return [] }
        var pages = notebook.sortedPages
        let ordered = selection.sorted { $0.sortIndex < $1.sortIndex }
        guard let last = ordered.last, let lastIndex = pages.firstIndex(where: { $0.id == last.id }) else { return [] }
        var copies: [Page] = []
        for page in ordered {
            let copy = clonePageMetadata(page, sortIndex: 0)
            copy.notebook = notebook
            context.insert(copy)
            store.duplicateContent(from: page.id, to: copy.id)
            copies.append(copy)
        }
        pages.insert(contentsOf: copies, at: lastIndex + 1)
        renumber(pages)
        notebook.touch()
        try save()
        return copies
    }

    /// Moves pages within their notebook so they appear before `target` (nil = end).
    func reorder(_ moving: [Page], in notebook: Notebook, before target: Page?) throws {
        let movingIDs = Set(moving.map(\.id))
        var pages = notebook.sortedPages
        let moved = pages.filter { movingIDs.contains($0.id) }
        pages.removeAll { movingIDs.contains($0.id) }
        let insertAt = target.flatMap { t in pages.firstIndex { $0.id == t.id } } ?? pages.count
        pages.insert(contentsOf: moved, at: insertAt)
        renumber(pages)
        notebook.touch()
        try save()
    }

    /// Index-based move used by `List.onMove`.
    func movePages(in notebook: Notebook, fromOffsets source: IndexSet, toOffset destination: Int) throws {
        let pages = notebook.sortedPages
        let moving = source.filter { $0 < pages.count }.map { pages[$0] }
        var remaining = pages.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        // Destination is expressed in the original indexing; shift by the moved items before it.
        let adjusted = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(adjusted, 0), remaining.count))
        renumber(remaining)
        notebook.touch()
        try save()
    }

    /// Moves pages to another notebook, keeping their relative order. Files are keyed by
    /// page ID so nothing on disk needs to move.
    func movePages(_ moving: [Page], to destination: Notebook, at index: Int? = nil) throws {
        let ordered = moving.sorted { ($0.notebook?.title ?? "", $0.sortIndex) < ($1.notebook?.title ?? "", $1.sortIndex) }
        let sources = Set(ordered.compactMap(\.notebook))
        let movingIDs = Set(ordered.map(\.id))
        var destinationPages = destination.sortedPages.filter { !movingIDs.contains($0.id) }
        for page in ordered { page.notebook = destination }
        let insertAt = min(max(index ?? destinationPages.count, 0), destinationPages.count)
        destinationPages.insert(contentsOf: ordered, at: insertAt)
        renumber(destinationPages)
        for source in sources where source.persistentModelID != destination.persistentModelID {
            renumber(source.sortedPages.filter { !movingIDs.contains($0.id) })
            source.touch()
        }
        destination.touch()
        try save()
    }

    // MARK: Copy & paste

    func snapshot(of pages: [Page]) -> [PageSnapshot] {
        store.flush()
        return pages.sorted { $0.sortIndex < $1.sortIndex }.map { page in
            PageSnapshot(title: page.title, style: page.style, size: page.size,
                         pdfFileName: page.pdfFileName, pdfPageIndex: page.pdfPageIndex,
                         pdfText: page.pdfText, recognizedText: page.recognizedText,
                         elementsText: page.elementsText,
                         content: store.loadContentSync(pageID: page.id))
        }
    }

    @discardableResult
    func paste(_ snapshots: [PageSnapshot], into notebook: Notebook, at index: Int? = nil) throws -> [Page] {
        var pages = notebook.sortedPages
        let insertAt = min(max(index ?? pages.count, 0), pages.count)
        var created: [Page] = []
        for snapshot in snapshots {
            // Skip PDF pages whose source document has since been deleted.
            if let name = snapshot.pdfFileName,
               !FileManager.default.fileExists(atPath: store.pdfURL(named: name).path) { continue }
            let page = Page(style: snapshot.style, sortIndex: 0, size: snapshot.size)
            page.title = snapshot.title
            page.pdfFileName = snapshot.pdfFileName
            page.pdfPageIndex = snapshot.pdfPageIndex
            page.pdfText = snapshot.pdfText
            page.recognizedText = snapshot.recognizedText
            page.elementsText = snapshot.elementsText
            page.notebook = notebook
            try store.write(content: snapshot.content, pageID: page.id)
            context.insert(page)
            created.append(page)
        }
        pages.insert(contentsOf: created, at: insertAt)
        renumber(pages)
        notebook.touch()
        try save()
        return created
    }

    // MARK: Content bookkeeping

    /// Called by the editor after it has enqueued a content write.
    func contentDidChange(_ page: Page, elementsText: String? = nil) {
        page.markContentChanged()
        if let elementsText { page.elementsText = elementsText }
        page.notebook?.touch()
        try? save()
    }

    func updateRecognizedText(_ page: Page, text: String, version: Int) {
        page.recognizedText = text
        page.recognizedVersion = version
        try? save()
    }

    // MARK: Audio

    func addRecording(_ recording: AudioRecording, to notebook: Notebook) throws {
        recording.notebook = notebook
        context.insert(recording)
        try save()
    }

    func deleteRecording(_ recording: AudioRecording) throws {
        let name = recording.fileName
        context.delete(recording)
        try save()
        store.deleteAudio(named: name)
    }

    func renameRecording(_ recording: AudioRecording, to title: String) throws {
        recording.title = title
        try save()
    }

    // MARK: Templates

    @discardableResult
    func saveTemplate(name: String, style: PageStyle) throws -> TemplatePreset {
        let preset = TemplatePreset(name: Self.cleanName(name, fallback: "Custom Template"), style: style)
        context.insert(preset)
        try save()
        return preset
    }

    func deleteTemplate(_ preset: TemplatePreset) throws {
        context.delete(preset)
        try save()
    }

    // MARK: Maintenance

    /// Deletes image assets no page references. Run once at launch (before any undo history exists).
    func collectGarbage() {
        guard let fileStore = store as? FilePageContentStore,
              let pages = try? context.fetch(FetchDescriptor<Page>()) else { return }
        let ids = pages.map(\.id)
        Task.detached(priority: .background) {
            let referenced = fileStore.referencedAssetNames(pageIDs: ids)
            fileStore.collectUnreferencedAssets(keeping: referenced)
        }
    }

    // MARK: Helpers

    private func renumber(_ pages: [Page]) {
        for (index, page) in pages.enumerated() where page.sortIndex != index {
            page.sortIndex = index
        }
    }

    private func clonePageMetadata(_ page: Page, sortIndex: Int) -> Page {
        let copy = Page(style: page.style, sortIndex: sortIndex, size: page.size)
        copy.title = page.title
        copy.pdfFileName = page.pdfFileName
        copy.pdfPageIndex = page.pdfPageIndex
        copy.pdfText = page.pdfText
        copy.recognizedText = page.recognizedText
        copy.recognizedVersion = page.recognizedVersion >= 0 ? 0 : -1
        copy.elementsText = page.elementsText
        copy.isBookmarked = page.isBookmarked
        return copy
    }

    private struct FileCleanup {
        var pageIDs: [UUID] = []
        var pdfNames: Set<String> = []
        var audioNames: [String] = []
    }

    private func collectFiles(for notebooks: [Notebook]) -> FileCleanup {
        var cleanup = FileCleanup()
        for notebook in notebooks {
            for page in notebook.pages ?? [] {
                cleanup.pageIDs.append(page.id)
                if let pdf = page.pdfFileName { cleanup.pdfNames.insert(pdf) }
            }
            cleanup.audioNames += (notebook.recordings ?? []).map(\.fileName)
        }
        return cleanup
    }

    private func purge(_ cleanup: FileCleanup) {
        store.deleteContent(pageIDs: cleanup.pageIDs)
        cleanup.audioNames.forEach { store.deleteAudio(named: $0) }
        deleteUnreferencedPDFs(cleanup.pdfNames)
    }

    /// PDFs can be shared by several pages (duplicates, pastes); only delete
    /// a document once no remaining page points to it.
    private func deleteUnreferencedPDFs(_ names: Set<String>) {
        for name in names {
            let descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.pdfFileName == name })
            if ((try? context.fetchCount(descriptor)) ?? 1) == 0 {
                store.deletePDF(named: name)
            }
        }
    }

    static func cleanName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
