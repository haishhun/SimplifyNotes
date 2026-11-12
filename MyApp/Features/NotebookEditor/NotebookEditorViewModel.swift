import SwiftData
import SwiftUI
import PencilKit
import Observation
import os

/// Sheets and popovers the editor can present.
enum EditorSheet: Identifiable {
    case pageOverview
    case pageStyle
    case export([ExportPageItem])
    case textEditor(PageElement, isNew: Bool)
    case crop(PageElement)
    case recognition(String)
    case linkPicker
    case audio
    case search

    var id: String {
        switch self {
        case .pageOverview: "overview"
        case .pageStyle: "style"
        case .export: "export"
        case .textEditor(let element, _): "text-\(element.id)"
        case .crop(let element): "crop-\(element.id)"
        case .recognition: "recognition"
        case .linkPicker: "link"
        case .audio: "audio"
        case .search: "search"
        }
    }
}

@Observable
final class NotebookEditorViewModel: PageCanvasControllerDelegate {
    let notebook: Notebook
    let env: AppEnvironment

    private(set) var pages: [Page] = []
    private(set) var currentPageID: UUID?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var hasInkSelection = false
    private(set) var selectedElement: PageElement?
    private(set) var isRecognizing = false
    var activeSheet: EditorSheet?
    var isShowingToolOptions = false
    var isShowingColorPicker = false
    var isRulerActive = false { didSet { canvas?.isRulerActive = isRulerActive } }
    var showPageSidebar: Bool {
        get { env.settings.showPageSidebar }
        set { env.settings.showPageSidebar = newValue }
    }

    @ObservationIgnored weak var canvas: PageCanvasController?
    /// Page whose content is currently on the canvas (may lag `currentPageID` while loading).
    @ObservationIgnored private var displayedPageID: UUID?
    @ObservationIgnored private var pendingInk = false
    @ObservationIgnored private var pendingElements = false
    @ObservationIgnored private var undoManagers: [UUID: UndoManager] = [:]
    /// Small LRU of recently visited pages so flipping back is instant and keeps undo history.
    @ObservationIgnored private var contentCache: [UUID: PageContent] = [:]
    @ObservationIgnored private var cacheOrder: [UUID] = []
    @ObservationIgnored private let cacheLimit = 6
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private(set) lazy var autosave = AutosaveScheduler { [weak self] in self?.saveNow() }

    var store: PageContentStoring { env.store }
    var tools: ToolSettings { env.tools }

    /// Side-effect free: SwiftUI may construct the editor's view several times.
    /// Anything that writes data happens once, in `start()`.
    init(notebook: Notebook, env: AppEnvironment, initialPageID: UUID? = nil) {
        self.notebook = notebook
        self.env = env
        pages = notebook.sortedPages
        let lastIndex = min(max(notebook.lastPageIndex, 0), max(pages.count - 1, 0))
        currentPageID = initialPageID ?? pages[safe: lastIndex]?.id
    }

    @ObservationIgnored private var hasStarted = false

    /// Called once when the editor appears.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        if pages.isEmpty, let page = try? env.repository.addPage(to: notebook) {
            pages = [page]
            currentPageID = page.id
        }
        env.repository.markOpened(notebook)
        resignObserver = NotificationCenter.default.addObserver(forName: .inkwellWillResignActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave.flush() }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: Pages

    var currentIndex: Int { pages.firstIndex { $0.id == currentPageID } ?? 0 }
    var currentPage: Page? { pages.first { $0.id == currentPageID } }
    var pageLabel: String { pages.isEmpty ? "" : "\(currentIndex + 1) of \(pages.count)" }

    func attach(_ canvas: PageCanvasController) {
        self.canvas = canvas
        canvas.delegate = self
        applyTool()
        loadCurrentPage()
    }

    func reloadPages() {
        autosave.flush()
        let previousIndex = currentIndex
        pages = notebook.sortedPages
        let ids = Set(pages.map(\.id))
        // Forget state for pages that were deleted or moved away.
        for id in Array(contentCache.keys) where !ids.contains(id) { evict(id) }
        if pages.isEmpty, let page = try? env.repository.addPage(to: notebook) { pages = [page] }
        if let id = currentPageID, ids.contains(id) {
            if let page = currentPage, page.id == displayedPageID { canvas?.updatePage(canvasModel(for: page)) }
        } else {
            currentPageID = pages[safe: min(previousIndex, pages.count - 1)]?.id
            loadCurrentPage()
        }
    }

    func go(to index: Int) {
        guard let page = pages[safe: index], page.id != currentPageID else { return }
        go(toPageID: page.id)
    }

    func go(toPageID id: UUID) {
        guard pages.contains(where: { $0.id == id }) else { return }
        autosave.flush()
        cacheDisplayedContent()
        currentPageID = id
        notebook.lastPageIndex = currentIndex
        loadCurrentPage()
    }

    func nextPage() {
        if currentIndex + 1 < pages.count { go(to: currentIndex + 1) } else { addPage(after: true) }
    }

    func previousPage() { go(to: currentIndex - 1) }

    func addPage(after: Bool = true, style: PageStyle? = nil) {
        autosave.flush()
        let index = after ? currentIndex + 1 : currentIndex
        let baseStyle = style ?? currentPage.map { page -> PageStyle in
            var s = page.isPDFBacked ? notebook.defaultStyle : page.style
            if page.isPDFBacked && s.template == .blank { s.template = env.settings.defaultStyle.template }
            return s
        }
        env.perform {
            let page = try env.repository.addPage(to: notebook, at: index, style: baseStyle)
            pages = notebook.sortedPages
            go(toPageID: page.id)
        }
    }

    func duplicateCurrentPage() {
        guard let page = currentPage else { return }
        autosave.flush()
        env.perform {
            let copies = try env.repository.duplicatePages([page])
            pages = notebook.sortedPages
            if let copy = copies.first { go(toPageID: copy.id) }
        }
    }

    func deleteCurrentPage() {
        guard let page = currentPage else { return }
        autosave.cancel()
        pendingInk = false
        pendingElements = false
        let id = page.id
        displayedPageID = nil
        env.perform {
            try env.repository.deletePages([page])
        }
        evict(id)
        reloadPages()
    }

    func toggleBookmark() {
        guard let page = currentPage else { return }
        env.perform { try env.repository.setBookmarked([page], !page.isBookmarked) }
    }

    func renameCurrentPage(_ title: String) {
        guard let page = currentPage else { return }
        env.perform { try env.repository.renamePage(page, to: title) }
    }

    func applyStyle(_ style: PageStyle, scope: StyleScope) {
        autosave.flush()
        let targets: [Page]
        switch scope {
        case .currentPage: targets = currentPage.map { [$0] } ?? []
        case .allPages: targets = pages
        }
        env.perform {
            try env.repository.applyStyle(style, to: targets)
            if scope == .allPages || notebook.pageCount == 1 { notebook.defaultStyle = style }
            try env.repository.save()
        }
        if let page = currentPage { canvas?.updatePage(canvasModel(for: page)) }
    }

    enum StyleScope { case currentPage, allPages }

    private func canvasModel(for page: Page) -> CanvasPageModel {
        CanvasPageModel(pageID: page.id, size: page.size, style: page.style,
                        pdfURL: page.pdfFileName.map { store.pdfURL(named: $0) }, pdfPageIndex: page.pdfPageIndex)
    }

    private func loadCurrentPage() {
        guard let canvas, let page = currentPage else { return }
        loadTask?.cancel()
        let id = page.id
        let model = canvasModel(for: page)
        if let cached = contentCache[id] {
            show(model, content: cached, on: canvas)
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let content = await store.loadContent(pageID: id)
            guard !Task.isCancelled, self.currentPageID == id else { return }
            if content.recoveredFromBackup {
                self.env.presentedError = "This page couldn't be read normally and was restored from its most recent backup."
            }
            // Fresh history for content loaded from disk.
            self.undoManagers[id] = nil
            self.show(model, content: content, on: canvas)
        }
    }

    private func show(_ model: CanvasPageModel, content: PageContent, on canvas: PageCanvasController) {
        displayedPageID = model.pageID
        touchCache(model.pageID, content: content)
        canvas.display(model, content: content, undoManager: undoManager(for: model.pageID), assetURL: store.assetURL(named:))
        canvas.isRulerActive = isRulerActive
        applyTool()
        refreshUndoState()
        refreshSelection()
        scheduleRecognitionIfStale()
    }

    private func undoManager(for id: UUID) -> UndoManager {
        if let manager = undoManagers[id] { return manager }
        let manager = UndoManager()
        manager.levelsOfUndo = 200
        undoManagers[id] = manager
        return manager
    }

    // MARK: Content cache

    private func cacheDisplayedContent() {
        guard let canvas, let id = displayedPageID else { return }
        touchCache(id, content: PageContent(drawing: canvas.drawing, elements: canvas.elements))
    }

    private func touchCache(_ id: UUID, content: PageContent) {
        contentCache[id] = content
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > cacheLimit {
            evict(cacheOrder.removeFirst())
        }
    }

    private func evict(_ id: UUID) {
        contentCache[id] = nil
        undoManagers[id] = nil
        cacheOrder.removeAll { $0 == id }
    }

    // MARK: Saving

    /// Writes pending ink/elements for the displayed page. Serialisation and disk I/O
    /// happen on the store's background queue.
    func saveNow() {
        guard let canvas, let id = displayedPageID, pendingInk || pendingElements,
              let page = pages.first(where: { $0.id == id }) else { return }
        // The page may have been deleted elsewhere (page overview); never resurrect its files.
        guard !page.isDeleted, page.modelContext != nil else {
            pendingInk = false
            pendingElements = false
            return
        }
        let drawing = canvas.drawing
        let elements = canvas.elements
        if pendingInk { store.save(drawing: drawing, pageID: id) }
        var elementsText: String?
        if pendingElements {
            store.save(elements: elements, pageID: id)
            elementsText = elements.filter { $0.kind != .image }.map(\.text).joined(separator: "\n")
        }
        pendingInk = false
        pendingElements = false
        touchCache(id, content: PageContent(drawing: drawing, elements: elements))
        env.repository.contentDidChange(page, elementsText: elementsText)
        scheduleRecognition(for: page, drawing: drawing)
    }

    /// Called when the editor closes.
    func close() {
        autosave.flush()
        recognitionTask?.cancel()
        loadTask?.cancel()
        if let finished = env.audio.stopRecording() { storeRecording(finished) }
        env.audio.stopPlayback()
        notebook.lastPageIndex = currentIndex
        try? env.repository.save()
        env.store.flush()
    }

    // MARK: Handwriting indexing

    private func scheduleRecognitionIfStale() {
        guard let page = currentPage, page.recognizedVersion != page.contentVersion, let canvas else { return }
        scheduleRecognition(for: page, drawing: canvas.drawing)
    }

    private func scheduleRecognition(for page: Page, drawing: PKDrawing) {
        guard env.settings.handwritingIndexing else { return }
        recognitionTask?.cancel()
        let version = page.contentVersion
        if drawing.strokes.isEmpty {
            if !page.recognizedText.isEmpty || page.recognizedVersion != version {
                env.repository.updateRecognizedText(page, text: "", version: version)
            }
            return
        }
        recognitionTask = Task { [weak self] in
            // Wait for a pause in writing; recognition never competes with active inking.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let text = (try? await HandwritingRecognitionService.recognize(drawing: drawing)) ?? ""
            guard !Task.isCancelled, let self, page.contentVersion == version else { return }
            self.env.repository.updateRecognizedText(page, text: text, version: version)
        }
    }

    // MARK: Tools

    func select(_ tool: ToolKind) {
        if tools.currentTool == tool, tool.isInking || tool == .eraser {
            isShowingToolOptions.toggle()
            return
        }
        tools.currentTool = tool
        isShowingToolOptions = false
        applyTool()
    }

    func applyTool() {
        let policy: PKCanvasViewDrawingPolicy
        switch env.settings.inputPolicy {
        // `.default` only lets fingers draw while the system tool picker is visible, which this
        // app doesn't use, so "Automatic" resolves the user's system preference explicitly.
        case .automatic: policy = UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilOnly : .anyInput
        case .pencilOnly: policy = .pencilOnly
        case .anyInput: policy = .anyInput
        }
        let kind = tools.currentTool
        canvas?.apply(tool: kind, pkTool: tools.pkTool(for: kind), policy: policy, autoShape: env.settings.autoShapeCorrection)
    }

    func selectColor(_ hex: String) {
        if hasInkSelection {
            canvas?.recolorSelectedInk(UIColor(hex: hex))
            return
        }
        if var element = selectedElement, element.kind != .image {
            element.colorHex = hex
            canvas?.updateElement(element)
            return
        }
        var tool = tools.currentTool
        if !tool.isInking { tool = tools.previousTool.isInking ? tools.previousTool : .ballpoint; tools.currentTool = tool }
        tools.updatePreset(for: tool) { $0.colorHex = hex }
        applyTool()
    }

    func handlePencilDoubleTap() {
        let action: DoubleTapAction
        switch env.settings.doubleTapAction {
        case .system:
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser: action = .eraser
            case .switchPrevious: action = .previousTool
            case .showColorPalette:
                isShowingColorPicker.toggle(); return
            case .showInkAttributes, .showContextualPalette:
                isShowingToolOptions.toggle(); return
            default: action = .nothing
            }
        default:
            action = env.settings.doubleTapAction
        }
        switch action {
        case .eraser:
            if tools.currentTool == .eraser { tools.switchToPrevious() } else { tools.currentTool = .eraser }
        case .previousTool:
            tools.switchToPrevious()
        case .system, .nothing:
            return
        }
        applyTool()
    }

    // MARK: Undo

    func undo() { canvas?.undo() }
    func redo() { canvas?.redo() }

    private func refreshUndoState() {
        let newUndo = canvas?.canUndo ?? false
        let newRedo = canvas?.canRedo ?? false
        if newUndo != canUndo { canUndo = newUndo }
        if newRedo != canRedo { canRedo = newRedo }
    }

    private func refreshSelection() {
        let ink = canvas?.hasInkSelection ?? false
        if ink != hasInkSelection { hasInkSelection = ink }
        let element = canvas?.selectedElement
        if element != selectedElement { selectedElement = element }
    }

    // MARK: Selection actions

    func copySelection() { canvas?.copySelectedInk() }
    func cutSelection() { canvas?.cutSelectedInk() }
    func deleteSelection() {
        if hasInkSelection { canvas?.deleteSelectedInk() } else { canvas?.deleteSelectedElement() }
    }
    func duplicateSelection() {
        if hasInkSelection { canvas?.duplicateSelectedInk() } else { canvas?.duplicateSelectedElement() }
    }
    func pasteInk() {
        if tools.currentTool != .lasso { tools.currentTool = .lasso; applyTool() }
        canvas?.pasteInk()
    }
    var canPasteInk: Bool { canvas?.canPasteInk ?? false }

    func convertSelectionToText() {
        guard let drawing = canvas?.selectedInkDrawing() else { return }
        isRecognizing = true
        Task {
            defer { isRecognizing = false }
            do {
                let text = try await HandwritingRecognitionService.recognize(drawing: drawing)
                activeSheet = .recognition(text)
            } catch {
                env.presentedError = error.localizedDescription
            }
        }
    }

    /// Inserts recognised text as a text box where the ink was.
    func insertRecognizedText(_ text: String, replaceInk: Bool) {
        guard let canvas else { return }
        let bounds = canvas.selectedInkBounds
        let origin = bounds.isNull ? canvas.visibleCenterInPage() : bounds.origin
        var element = PageElement.textBox(at: origin, text: text, width: max(bounds.isNull ? 300 : bounds.width + 24, 160))
        element.fontSize = 20
        canvas.replaceSelectedInk(with: element, keepInk: !replaceInk)
        if tools.currentTool != .objects { tools.currentTool = .objects; applyTool() }
    }

    // MARK: Elements

    func saveTextElement(_ element: PageElement, isNew: Bool) {
        let trimmed = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            guard !trimmed.isEmpty else { return }
            canvas?.insertElement(element)
        } else if trimmed.isEmpty {
            canvas?.selectElement(element.id)
            canvas?.deleteSelectedElement()
        } else {
            canvas?.updateElement(element)
        }
    }

    func insertImage(data: Data) {
        guard let image = UIImage(data: data) else {
            env.presentedError = AppError.imageUnreadable.localizedDescription
            return
        }
        Task {
            // Normalise orientation and size off the main thread before storing.
            let prepared = await Task.detached(priority: .userInitiated) { () -> (Data, String, CGSize)? in
                Self.prepareImageForStorage(image)
            }.value
            guard let (stored, ext, size) = prepared else {
                env.presentedError = AppError.imageUnreadable.localizedDescription
                return
            }
            env.perform {
                let name = try store.importAsset(data: stored, fileExtension: ext)
                guard let canvas else { return }
                let maxWidth = min(canvas.visibleWidthInPage * 0.7, (currentPage?.size.width ?? 612) * 0.8)
                let scale = min(maxWidth / max(size.width, 1), 1.0 * 400 / max(size.height, 1), 1)
                let frameSize = CGSize(width: max(size.width * scale, 60), height: max(size.height * scale, 60))
                let center = canvas.visibleCenterInPage()
                let frame = CGRect(x: center.x - frameSize.width / 2, y: center.y - frameSize.height / 2,
                                   width: frameSize.width, height: frameSize.height)
                if tools.currentTool != .objects { tools.currentTool = .objects; applyTool() }
                canvas.insertElement(.image(assetName: name, frame: frame))
            }
        }
    }

    nonisolated static func prepareImageForStorage(_ image: UIImage) -> (Data, String, CGSize)? {
        let maxDimension: CGFloat = 2400
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let hasAlpha: Bool = {
            guard let alpha = image.cgImage?.alphaInfo else { return false }
            return [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
        }()
        format.opaque = !hasAlpha
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if hasAlpha, let png = rendered.pngData() { return (png, "png", target) }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.88) else { return nil }
        return (jpeg, "jpg", target)
    }

    func applyCrop(to element: PageElement, croppedImage: UIImage) {
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepareImageForStorage(croppedImage) }.value
            guard let (data, ext, size) = prepared else { return }
            env.perform {
                let name = try store.importAsset(data: data, fileExtension: ext)
                var updated = element
                updated.assetName = name
                // Keep the width, adapt height to the new aspect ratio.
                updated.frame.size.height = element.frame.width * size.height / max(size.width, 1)
                canvas?.updateElement(updated)
            }
        }
    }

    func insertLink(to target: Page) {
        guard let canvas else { return }
        let index = pages.firstIndex { $0.id == target.id } ?? 0
        let label = target.displayTitle(index: index)
        let center = canvas.visibleCenterInPage()
        if tools.currentTool != .objects { tools.currentTool = .objects; applyTool() }
        canvas.insertElement(.link(to: target.id, label: label, at: CGPoint(x: center.x - 100, y: center.y)))
    }

    // MARK: Audio

    func toggleRecording() {
        if env.audio.isRecording {
            if let finished = env.audio.stopRecording() { storeRecording(finished) }
            return
        }
        Task {
            do {
                try await env.audio.startRecording(store: store)
            } catch {
                env.presentedError = error.localizedDescription
            }
        }
    }

    private func storeRecording(_ finished: AudioNoteService.FinishedRecording) {
        let title = Date.now.formatted(date: .abbreviated, time: .shortened)
        let recording = AudioRecording(title: title, fileName: finished.fileName, duration: finished.duration, pageID: currentPageID)
        env.perform { try env.repository.addRecording(recording, to: notebook) }
    }

    // MARK: Export

    func exportItems(for pagesToExport: [Page]) -> [ExportPageItem] {
        autosave.flush()
        return pagesToExport.map { page in
            let number = (pages.firstIndex { $0.id == page.id } ?? 0) + 1
            return ExportPageItem(snapshot: page.renderSnapshot(store: store), notebookTitle: notebook.title, pageNumber: number)
        }
    }

    // MARK: PageCanvasControllerDelegate

    func canvasDidChangeDrawing() {
        pendingInk = true
        autosave.markDirty()
    }

    func canvasDidChangeElements() {
        pendingElements = true
        autosave.markDirty()
    }

    func canvasUndoStateDidChange() { refreshUndoState() }
    func canvasSelectionDidChange() { refreshSelection() }

    func canvasRequestsTextEditing(_ element: PageElement, isNew: Bool) {
        activeSheet = .textEditor(element, isNew: isNew)
    }

    func canvasDidActivateLink(to pageID: UUID) {
        if pages.contains(where: { $0.id == pageID }) {
            go(toPageID: pageID)
        } else {
            env.presentedError = "The linked page no longer exists in this notebook."
        }
    }

    func canvasPencilDoubleTapped() { handlePencilDoubleTap() }
    func canvasPencilSqueezed() { isShowingToolOptions.toggle() }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
