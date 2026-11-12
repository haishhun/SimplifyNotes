import SwiftUI
import Observation

/// State for building a (possibly multi-notebook) PDF: an ordered queue of pages plus options.
@Observable
final class ExportComposerViewModel {
    private(set) var queue: [ExportPageItem]
    var options = PDFExportOptions()
    private(set) var isExporting = false
    private(set) var progress: Double = 0
    var previewURL: URL?
    var errorMessage: String?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private let store: PageContentStoring

    init(items: [ExportPageItem], title: String, store: PageContentStoring) {
        self.queue = items
        self.store = store
        options.title = title
    }

    // MARK: Queue editing

    /// Appends pages in notebook order, or in the given order when `preservingOrder` is set
    /// (e.g. a typed range like "5, 2").
    func add(_ pages: [Page], from notebook: Notebook, preservingOrder: Bool = false) {
        let ordered = notebook.sortedPages
        let source = preservingOrder ? pages : pages.sorted { $0.sortIndex < $1.sortIndex }
        let items = source.map { page in
            ExportPageItem(snapshot: page.renderSnapshot(store: store), notebookTitle: notebook.title,
                           pageNumber: (ordered.firstIndex { $0.id == page.id } ?? 0) + 1)
        }
        queue.append(contentsOf: items)
        invalidatePreview()
    }

    /// Adds pages using a range expression like "1-3, 7".
    func addRange(_ text: String, from notebook: Notebook) throws {
        let pages = notebook.sortedPages
        let indices = try PageRangeParser.parse(text, pageCount: pages.count)
        add(indices.map { pages[$0] }, from: notebook, preservingOrder: true)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { queue[$0] }
        var remaining = queue.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let adjusted = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(adjusted, 0), remaining.count))
        queue = remaining
        invalidatePreview()
    }

    func remove(atOffsets offsets: IndexSet) {
        queue = queue.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        invalidatePreview()
    }

    func removeAll() {
        queue.removeAll()
        invalidatePreview()
    }

    func reverse() {
        queue.reverse()
        invalidatePreview()
    }

    func invalidatePreview() {
        exportTask?.cancel()
        previewURL = nil
    }

    // MARK: Export

    /// Generates the PDF in the background; progress is reported on the main actor.
    func generate() {
        guard !queue.isEmpty else {
            errorMessage = AppError.nothingToExport.localizedDescription
            return
        }
        exportTask?.cancel()
        isExporting = true
        progress = 0
        let items = queue
        let options = options
        let store = store
        let url = PDFExportService.temporaryURL(named: options.title)
        exportTask = Task { [weak self] in
            do {
                let result = try await PDFExportService.export(items, options: options, store: store, to: url) { value in
                    Task { @MainActor in self?.progress = value }
                }
                guard !Task.isCancelled else { return }
                self?.previewURL = result
            } catch is CancellationError {
                // Superseded by a newer request.
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isExporting = false
        }
    }

    func cancel() {
        exportTask?.cancel()
        isExporting = false
    }
}
