import UIKit
import PencilKit
import UniformTypeIdentifiers
import os

/// PKCanvasView that uses a per-page undo manager, giving every page its own reliable history.
final class InkCanvasView: PKCanvasView {
    var pageUndoManager: UndoManager?
    override var undoManager: UndoManager? { pageUndoManager ?? super.undoManager }
}

@MainActor
protocol PageCanvasControllerDelegate: AnyObject {
    func canvasDidChangeDrawing()
    func canvasDidChangeElements()
    func canvasUndoStateDidChange()
    func canvasSelectionDidChange()
    func canvasRequestsTextEditing(_ element: PageElement, isNew: Bool)
    func canvasDidActivateLink(to pageID: UUID)
    func canvasPencilDoubleTapped()
    func canvasPencilSqueezed()
}

/// What the canvas is currently showing.
struct CanvasPageModel: Equatable {
    let pageID: UUID
    var size: CGSize
    var style: PageStyle
    var pdfURL: URL?
    var pdfPageIndex: Int
}

/// UIKit host for one page: zoomable PencilKit canvas + paper/PDF underlay +
/// selection overlay. All editing logic that must run at touch speed lives here,
/// outside of SwiftUI, so strokes never trigger SwiftUI view updates.
/// Forwards gesture-delegate calls; `UIView` already defines `gestureRecognizerShouldBegin(_:)`,
/// so the canvas controller can't be the delegate itself.
private final class CanvasGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: PageCanvasController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        owner?.interactionShouldBegin(gestureRecognizer) ?? false
    }

    fileprivate func interactionShouldReceive(_ gestureRecognizer: UIGestureRecognizer, touch: UITouch) -> Bool {
        owner?.interactionShouldReceive(gestureRecognizer, touch: touch) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        owner?.interactionShouldRecognizeSimultaneously(gestureRecognizer, with: other) ?? false
    }
}

/// Transparent layer above the canvas that claims a touch only when it lands on a lasso
/// selection, a selection handle or an object. Those drags then never compete with
/// PencilKit's internal gesture recognizers (which otherwise hold a pan back until the finger
/// lifts if it rests briefly first). All other touches fall through to the canvas.
private final class ManipulationLayerView: UIView {
    var capturesPoint: ((CGPoint) -> Bool)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        capturesPoint?(point) ?? false
    }
}

final class PageCanvasController: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    static let inkPasteboardType = "com.inkwell.pkdrawing"

    let canvas = InkCanvasView()
    let underlay = PageUnderlayView()
    let overlay = SelectionOverlayView()
    weak var delegate: PageCanvasControllerDelegate?

    private(set) var page: CanvasPageModel?

    /// How the next page change animates (consumed by `display`).
    enum PageTransition { case none, revealFromTop, revealFromBottom, duplicate }
    var pendingTransition: PageTransition = .none
    private var transitionSnapshot: UIView?
    private(set) var elements: [PageElement] = []
    private(set) var toolKind: ToolKind = .ballpoint
    var autoShapeCorrection = true
    /// True when a finger cannot draw (so finger taps can follow links etc.).
    private var fingerDrawingDisabled = true

    private var isApplyingDrawing = false
    private var lastStrokeCount = 0
    private var needsFit = true
    /// Width the page was last fitted to; refit when the canvas width changes.
    private var lastFitWidth: CGFloat = 0
    /// Once the user pinches, keep their zoom instead of refitting.
    private var userHasZoomed = false
    private let pagePadding: CGFloat = 28

    // Ink selection
    private(set) var selectedStrokeIndices = IndexSet()
    private var selectionBounds: CGRect = .null
    // Element selection
    private(set) var selectedElementID: UUID?

    private enum Interaction {
        case none
        case lasso([CGPoint])
        case transformInk(kind: InkTransformKind, start: CGPoint, original: PKDrawing, selected: [PKStroke], bounds: CGRect)
        case transformElement(kind: ElementTransformKind, start: CGPoint, original: PageElement)
    }
    private enum InkTransformKind { case move, scale, rotate }
    private enum ElementTransformKind { case move, resize, rotate }
    private var interaction: Interaction = .none
    private var lastTouchType: UITouch.TouchType = .direct

    private lazy var interactionPan = UIPanGestureRecognizer(target: self, action: #selector(handleInteractionPan(_:)))
    private lazy var interactionTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private let manipulationLayer = ManipulationLayerView()
    private lazy var manipulationPan = UIPanGestureRecognizer(target: self, action: #selector(handleInteractionPan(_:)))
    private lazy var manipulationTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private lazy var undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
    private lazy var redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
    private let gestureDelegate = CanvasGestureDelegate()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = self
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true
        // Ink is rendered with light-mode colours so it always matches the paper.
        canvas.overrideUserInterfaceStyle = .light
        canvas.accessibilityLabel = "Page canvas"
        canvas.accessibilityIdentifier = "pageCanvas"
        addSubview(canvas)
        canvas.insertSubview(underlay, at: 0)
        canvas.addSubview(overlay)

        gestureDelegate.owner = self
        interactionPan.maximumNumberOfTouches = 1
        interactionPan.delegate = gestureDelegate
        interactionTap.delegate = gestureDelegate
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = gestureDelegate
        redoTap.delegate = gestureDelegate
        undoTap.require(toFail: redoTap)
        [interactionPan, interactionTap, undoTap, redoTap].forEach(canvas.addGestureRecognizer)

        manipulationLayer.backgroundColor = .clear
        manipulationLayer.capturesPoint = { [weak self] point in
            self?.capturesManipulation(atLayerPoint: point) ?? false
        }
        manipulationPan.maximumNumberOfTouches = 1
        manipulationLayer.addGestureRecognizer(manipulationPan)
        manipulationLayer.addGestureRecognizer(manipulationTap)
        addSubview(manipulationLayer)
        canvas.panGestureRecognizer.require(toFail: interactionPan)

        let pencil = UIPencilInteraction(delegate: self)
        addInteraction(pencil)

        // PencilKit registers its undo action *after* `canvasViewDrawingDidChange`, so undo
        // availability must be read from the undo manager's own notifications.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint] {
            center.addObserver(self, selector: #selector(undoManagerDidChange(_:)), name: name, object: nil)
        }
    }

    @objc private func undoManagerDidChange(_ note: Notification) {
        guard let manager = note.object as? UndoManager, manager === canvas.pageUndoManager else { return }
        delegate?.canvasUndoStateDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Displaying pages

    var drawing: PKDrawing { canvas.drawing }

    func display(_ model: CanvasPageModel, content: PageContent, undoManager: UndoManager, assetURL: @escaping (String) -> URL) {
        let isNewPage = page?.pageID != model.pageID
        let transition = isNewPage && page != nil ? pendingTransition : .none
        pendingTransition = .none
        // Capture the outgoing page as it looks on screen before replacing it.
        finishTransitionImmediately()
        let outgoing = transition == .none ? nil : canvas.snapshotView(afterScreenUpdates: false)
        page = model
        clearSelection(notify: false)
        canvas.pageUndoManager = undoManager
        underlay.assetURL = assetURL
        underlay.configure(state: .init(style: model.style, size: model.size, pdfURL: model.pdfURL, pdfPageIndex: model.pdfPageIndex))
        overlay.configure(pageSize: model.size)
        applyDrawing(content.drawing, notify: false)
        elements = content.elements
        underlay.setElements(elements)
        if isNewPage { needsFit = true; userHasZoomed = false }
        setNeedsLayout()
        layoutIfNeeded()
        delegate?.canvasUndoStateDidChange()
        if let outgoing { animatePageChange(transition, outgoing: outgoing) }
    }

    // MARK: Page transitions

    /// Before: the old page slides down while the new one drops in from the top.
    /// After: the old page slides up while the new one rises from the bottom.
    /// Duplicate: the old page shrinks back and fades while the copy settles in front.
    private func animatePageChange(_ transition: PageTransition, outgoing: UIView) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        outgoing.frame = canvas.frame
        outgoing.isUserInteractionEnabled = false
        if transition == .duplicate || reduceMotion {
            insertSubview(outgoing, belowSubview: canvas)
        } else {
            insertSubview(outgoing, aboveSubview: canvas)
        }
        transitionSnapshot = outgoing

        let height = bounds.height
        var incomingStart = CGAffineTransform.identity
        var outgoingEnd = CGAffineTransform.identity
        var incomingStartAlpha: CGFloat = 1
        var outgoingEndAlpha: CGFloat = 1
        switch (transition, reduceMotion) {
        case (_, true):
            incomingStartAlpha = 0
            outgoingEndAlpha = 0
        case (.revealFromTop, _):
            incomingStart = CGAffineTransform(translationX: 0, y: -height)
            outgoingEnd = CGAffineTransform(translationX: 0, y: height)
        case (.revealFromBottom, _):
            incomingStart = CGAffineTransform(translationX: 0, y: height)
            outgoingEnd = CGAffineTransform(translationX: 0, y: -height)
        case (.duplicate, _):
            incomingStart = CGAffineTransform(translationX: 24, y: 32).scaledBy(x: 0.94, y: 0.94)
            incomingStartAlpha = 0
            outgoingEnd = CGAffineTransform(scaleX: 0.9, y: 0.9)
            outgoingEndAlpha = 0
        case (.none, _):
            break
        }

        canvas.transform = incomingStart
        canvas.alpha = incomingStartAlpha
        UIView.animate(withDuration: reduceMotion ? 0.25 : 0.45, delay: 0,
                       usingSpringWithDamping: reduceMotion ? 1 : 0.88, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.canvas.transform = .identity
            self.canvas.alpha = 1
            outgoing.transform = outgoingEnd
            outgoing.alpha = outgoingEndAlpha
        } completion: { _ in
            outgoing.removeFromSuperview()
            if self.transitionSnapshot === outgoing { self.transitionSnapshot = nil }
        }
    }

    /// Ends a running transition at once (e.g. when pages change again mid-animation).
    private func finishTransitionImmediately() {
        guard let snapshot = transitionSnapshot else { return }
        snapshot.layer.removeAllAnimations()
        snapshot.removeFromSuperview()
        transitionSnapshot = nil
        canvas.layer.removeAllAnimations()
        canvas.transform = .identity
        canvas.alpha = 1
    }

    /// Updates the background (template change) without touching ink.
    func updatePage(_ model: CanvasPageModel) {
        let sizeChanged = page?.size != model.size
        page = model
        underlay.configure(state: .init(style: model.style, size: model.size, pdfURL: model.pdfURL, pdfPageIndex: model.pdfPageIndex))
        overlay.configure(pageSize: model.size)
        if sizeChanged { needsFit = true; setNeedsLayout() }
    }

    // MARK: Layout & zoom

    override func layoutSubviews() {
        super.layoutSubviews()
        // Set size/center rather than frame: frame is undefined while a page transition transforms the canvas.
        if canvas.bounds.size != bounds.size { canvas.bounds.size = bounds.size }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if canvas.center != center { canvas.center = center }
        if manipulationLayer.frame != bounds { manipulationLayer.frame = bounds }
        guard let page, bounds.width > 0 else { return }
        let fit = fitWidthScale(for: page.size)
        canvas.minimumZoomScale = min(fit, fitPageScale(for: page.size)) * 0.6
        canvas.maximumZoomScale = max(fit * 6, 4)
        // The first layouts can happen mid-presentation at a transient size, so keep fitting
        // to the real width until the user takes over the zoom.
        let widthChanged = abs(bounds.width - lastFitWidth) > 1
        if needsFit || (!userHasZoomed && widthChanged) {
            needsFit = false
            lastFitWidth = bounds.width
            canvas.setZoomScale(fit, animated: false)
            updateContentLayout()
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        } else {
            updateContentLayout()
        }
        canvas.sendSubviewToBack(underlay)
        canvas.bringSubviewToFront(overlay)
    }

    private func fitWidthScale(for size: CGSize) -> CGFloat {
        max((bounds.width - pagePadding * 2) / max(size.width, 1), 0.1)
    }

    private func fitPageScale(for size: CGSize) -> CGFloat {
        min(fitWidthScale(for: size), max((bounds.height - pagePadding * 2) / max(size.height, 1), 0.1))
    }

    func zoomToFitWidth() {
        guard let page else { return }
        userHasZoomed = false
        canvas.setZoomScale(fitWidthScale(for: page.size), animated: true)
    }

    func zoomToFitPage() {
        guard let page else { return }
        canvas.setZoomScale(fitPageScale(for: page.size), animated: true)
    }

    private func updateContentLayout() {
        guard let page else { return }
        let zoom = canvas.zoomScale
        let contentSize = CGSize(width: page.size.width * zoom, height: page.size.height * zoom)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        underlay.setZoom(zoom)
        overlay.setZoom(zoom)
        // Center the page when it is smaller than the viewport.
        let horizontal = max((canvas.bounds.width - contentSize.width) / 2, pagePadding)
        let vertical = max((canvas.bounds.height - contentSize.height) / 2, pagePadding)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical + 80, right: horizontal)
        if canvas.contentInset != insets { canvas.contentInset = insets }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if scrollView.pinchGestureRecognizer?.state == .began || scrollView.pinchGestureRecognizer?.state == .changed {
            userHasZoomed = true
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentLayout()
    }

    /// Whether a touch at this point (in the manipulation layer) grabs the current selection.
    private func capturesManipulation(atLayerPoint layerPoint: CGPoint) -> Bool {
        guard page != nil else { return false }
        let point = pagePoint(fromCanvasPoint: manipulationLayer.convert(layerPoint, to: canvas))
        switch toolKind {
        case .lasso:
            return hasInkSelection && (overlay.handle(at: point) != nil || overlay.selectionContains(point))
        case .objects, .text:
            return (selectedElement != nil && overlay.handle(at: point) != nil) || element(at: point) != nil
        default:
            return false
        }
    }

    /// Converts a point in the canvas (scroll view content space) to page coordinates —
    /// the same mapping PencilKit uses for ink: content point ÷ zoom scale.
    private func pagePoint(fromCanvasPoint point: CGPoint) -> CGPoint {
        let zoom = max(canvas.zoomScale, 0.01)
        return CGPoint(x: point.x / zoom, y: point.y / zoom)
    }

    private func pagePoint(of gesture: UIGestureRecognizer) -> CGPoint {
        pagePoint(fromCanvasPoint: gesture.location(in: canvas))
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        underlay.updateRenderScale(scale * traitCollection.displayScale)
    }

    /// Center of the visible area in page coordinates (for placing pasted content).
    func visibleCenterInPage() -> CGPoint {
        let point = pagePoint(fromCanvasPoint: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        guard let page else { return point }
        return CGPoint(x: min(max(point.x, 40), page.size.width - 40), y: min(max(point.y, 40), page.size.height - 40))
    }

    var visibleWidthInPage: CGFloat {
        guard let page else { return 400 }
        return min(canvas.bounds.width / max(canvas.zoomScale, 0.01), page.size.width)
    }

    // MARK: Tools

    func apply(tool kind: ToolKind, pkTool: PKTool?, policy: PKCanvasViewDrawingPolicy, autoShape: Bool) {
        if kind != toolKind, kind != .lasso { clearInkSelection() }
        if kind != toolKind, kind != .objects, kind != .text { clearElementSelection() }
        toolKind = kind
        autoShapeCorrection = autoShape
        canvas.drawingPolicy = policy
        fingerDrawingDisabled = policy != .anyInput
        if kind.usesCanvasDrawing, let pkTool {
            canvas.drawingGestureRecognizer.isEnabled = true
            canvas.tool = pkTool
        } else {
            canvas.drawingGestureRecognizer.isEnabled = false
        }
    }

    var isRulerActive: Bool {
        get { canvas.isRulerActive }
        set { canvas.isRulerActive = newValue }
    }

    // MARK: Undo

    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas.undoManager?.canRedo ?? false }

    func undo() {
        clearSelection(notify: true)
        canvas.undoManager?.undo()
        delegate?.canvasUndoStateDidChange()
    }

    func redo() {
        clearSelection(notify: true)
        canvas.undoManager?.redo()
        delegate?.canvasUndoStateDidChange()
    }

    @objc private func handleUndoTap() { undo() }
    @objc private func handleRedoTap() { redo() }

    // MARK: PKCanvasViewDelegate

    private var previewHideTask: Task<Void, Never>?
    private var hidePreviewOnRender = false

    private func hidePreviewAfterNextRender() {
        hidePreviewOnRender = true
        previewHideTask?.cancel()
        // Fallback in case PencilKit doesn't report a render (e.g. nothing visibly changed).
        previewHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.finishPreviewHide()
        }
    }

    private func finishPreviewHide() {
        guard hidePreviewOnRender else { return }
        hidePreviewOnRender = false
        previewHideTask?.cancel()
        previewHideTask = nil
        overlay.endPreview()
    }

    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        finishPreviewHide()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing else { return }
        let strokes = canvasView.drawing.strokes
        let added = strokes.count == lastStrokeCount + 1
        lastStrokeCount = strokes.count
        if added, toolKind.isInking, let stroke = strokes.last {
            let wantsShape = toolKind == .shapes
                || (autoShapeCorrection && toolKind != .highlighter && StrokeTools.endHoldDuration(of: stroke) > 0.45)
            if wantsShape {
                // Defer: mutating the drawing inside its own change callback is not allowed.
                DispatchQueue.main.async { [weak self] in self?.correctShape(of: stroke) }
            }
        }
        delegate?.canvasDidChangeDrawing()
        delegate?.canvasUndoStateDidChange()
    }

    // MARK: Drawing mutations

    /// Replaces the drawing and registers an undo step.
    /// Replaces the drawing and registers an undo step back to `previous`
    /// (defaults to the drawing currently on the canvas).
    func setDrawing(_ newDrawing: PKDrawing, actionName: String, previous: PKDrawing? = nil) {
        let old = previous ?? canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.clearSelection(notify: true)
            target.setDrawing(old, actionName: actionName)
        }
        canvas.undoManager?.setActionName(actionName)
        applyDrawing(newDrawing, notify: true)
    }

    private func applyDrawing(_ newDrawing: PKDrawing, notify: Bool) {
        isApplyingDrawing = true
        canvas.drawing = newDrawing
        isApplyingDrawing = false
        lastStrokeCount = newDrawing.strokes.count
        if notify {
            delegate?.canvasDidChangeDrawing()
            delegate?.canvasUndoStateDidChange()
        }
    }

    private func correctShape(of stroke: PKStroke) {
        var current = canvas.drawing
        // Only correct if the stroke is still the most recent one.
        guard let last = current.strokes.last, last.path.creationDate == stroke.path.creationDate,
              last.renderBounds == stroke.renderBounds else { return }
        guard let shape = ShapeRecognizer.recognize(StrokeTools.points(of: stroke)) else { return }
        current.strokes.removeLast()
        current.strokes.append(contentsOf: StrokeTools.strokes(for: shape, like: stroke))
        setDrawing(current, actionName: "Shape")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Ink selection

    var hasInkSelection: Bool { !selectedStrokeIndices.isEmpty }

    private func selectStrokes(_ indices: IndexSet) {
        selectedStrokeIndices = indices
        let strokes = indices.compactMap { index in index < canvas.drawing.strokes.count ? canvas.drawing.strokes[index] : nil }
        selectionBounds = StrokeTools.bounds(of: strokes)
        if indices.isEmpty || selectionBounds.isNull {
            selectedStrokeIndices = []
            overlay.clearSelection()
        } else {
            overlay.showSelection(frame: selectionBounds.insetBy(dx: -6, dy: -6))
        }
        delegate?.canvasSelectionDidChange()
    }

    func clearInkSelection() {
        guard !selectedStrokeIndices.isEmpty else { return }
        selectedStrokeIndices = []
        selectionBounds = .null
        overlay.clearSelection()
        delegate?.canvasSelectionDidChange()
    }

    func clearSelection(notify: Bool) {
        let had = !selectedStrokeIndices.isEmpty || selectedElementID != nil
        selectedStrokeIndices = []
        selectionBounds = .null
        selectedElementID = nil
        overlay.clearSelection()
        overlay.clearLasso()
        if notify && had { delegate?.canvasSelectionDidChange() }
    }

    private var selectedStrokes: [PKStroke] {
        let strokes = canvas.drawing.strokes
        return selectedStrokeIndices.filter { $0 < strokes.count }.map { strokes[$0] }
    }

    func selectedInkDrawing() -> PKDrawing? {
        let strokes = selectedStrokes
        return strokes.isEmpty ? nil : PKDrawing(strokes: strokes)
    }

    var selectedInkBounds: CGRect { selectionBounds }

    func deleteSelectedInk() {
        guard hasInkSelection else { return }
        var drawing = canvas.drawing
        drawing.strokes = drawing.strokes.enumerated().filter { !selectedStrokeIndices.contains($0.offset) }.map(\.element)
        clearInkSelection()
        setDrawing(drawing, actionName: "Delete")
    }

    func copySelectedInk() {
        guard let selection = selectedInkDrawing() else { return }
        var item: [String: Any] = [Self.inkPasteboardType: selection.dataRepresentation()]
        var image: UIImage?
        PageRenderer.lightTraits.performAsCurrent {
            image = selection.image(from: selection.bounds.insetBy(dx: -4, dy: -4), scale: 2)
        }
        if let png = image?.pngData() { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item])
    }

    func cutSelectedInk() {
        copySelectedInk()
        deleteSelectedInk()
    }

    func duplicateSelectedInk() {
        let strokes = selectedStrokes
        guard !strokes.isEmpty else { return }
        insertStrokes(strokes.map { StrokeTools.transformed($0, by: CGAffineTransform(translationX: 24, y: 24)) }, actionName: "Duplicate")
    }

    var canPasteInk: Bool { UIPasteboard.general.contains(pasteboardTypes: [Self.inkPasteboardType]) }

    /// Pastes ink from the pasteboard centered in the visible area.
    func pasteInk() {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.inkPasteboardType),
              let pasted = try? PKDrawing(data: data), !pasted.strokes.isEmpty else { return }
        let center = visibleCenterInPage()
        let bounds = pasted.bounds
        let offset = CGAffineTransform(translationX: center.x - bounds.midX, y: center.y - bounds.midY)
        insertStrokes(pasted.strokes.map { StrokeTools.transformed($0, by: offset) }, actionName: "Paste")
    }

    private func insertStrokes(_ strokes: [PKStroke], actionName: String) {
        var drawing = canvas.drawing
        let start = drawing.strokes.count
        drawing.strokes.append(contentsOf: strokes)
        setDrawing(drawing, actionName: actionName)
        selectStrokes(IndexSet(start..<(start + strokes.count)))
    }

    func recolorSelectedInk(_ color: UIColor) {
        guard hasInkSelection else { return }
        var drawing = canvas.drawing
        for index in selectedStrokeIndices where index < drawing.strokes.count {
            drawing.strokes[index] = StrokeTools.recolored(drawing.strokes[index], color: color)
        }
        let selection = selectedStrokeIndices
        setDrawing(drawing, actionName: "Recolor")
        selectStrokes(selection)
    }

    /// Replaces the selected ink with a text box (handwriting → text conversion).
    func replaceSelectedInk(with element: PageElement, keepInk: Bool) {
        if !keepInk { deleteSelectedInk() } else { clearInkSelection() }
        insertElement(element)
    }

    // MARK: Elements

    var selectedElement: PageElement? {
        selectedElementID.flatMap { id in elements.first { $0.id == id } }
    }

    func setElements(_ newElements: [PageElement], actionName: String) {
        let old = elements
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            target.setElements(old, actionName: actionName)
        }
        canvas.undoManager?.setActionName(actionName)
        elements = newElements
        underlay.setElements(newElements)
        if let id = selectedElementID, !newElements.contains(where: { $0.id == id }) {
            selectedElementID = nil
            overlay.clearSelection()
            delegate?.canvasSelectionDidChange()
        } else if let element = selectedElement {
            overlay.showSelection(frame: element.frame, rotation: CGFloat(element.rotation))
        }
        delegate?.canvasDidChangeElements()
        delegate?.canvasUndoStateDidChange()
    }

    func insertElement(_ element: PageElement) {
        var element = element
        if element.kind == .text { element.frame.size.height = ElementStyle.fittingHeight(for: element) }
        setElements(elements + [element], actionName: "Insert")
        selectElement(element.id)
    }

    func updateElement(_ element: PageElement) {
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        var updated = element
        if updated.kind == .text { updated.frame.size.height = ElementStyle.fittingHeight(for: updated) }
        var all = elements
        all[index] = updated
        setElements(all, actionName: "Edit")
    }

    func deleteSelectedElement() {
        guard let id = selectedElementID else { return }
        setElements(elements.filter { $0.id != id }, actionName: "Delete")
    }

    func duplicateSelectedElement() {
        guard var copy = selectedElement else { return }
        copy.id = UUID()
        copy.frame = copy.frame.offsetBy(dx: 24, dy: 24)
        insertElement(copy)
    }

    func bringSelectedElementToFront() {
        guard let element = selectedElement else { return }
        setElements(elements.filter { $0.id != element.id } + [element], actionName: "Bring to Front")
    }

    func sendSelectedElementToBack() {
        guard let element = selectedElement else { return }
        setElements([element] + elements.filter { $0.id != element.id }, actionName: "Send to Back")
    }

    func selectElement(_ id: UUID?) {
        selectedElementID = id
        if let element = selectedElement {
            overlay.showSelection(frame: element.frame, rotation: CGFloat(element.rotation))
        } else {
            overlay.clearSelection()
        }
        delegate?.canvasSelectionDidChange()
    }

    func clearElementSelection() {
        guard selectedElementID != nil else { return }
        selectElement(nil)
    }

    private func element(at point: CGPoint) -> PageElement? {
        elements.reversed().first { $0.contains(point, tolerance: 6 / max(canvas.zoomScale, 0.1)) }
    }

    // MARK: Gestures

    fileprivate func interactionShouldReceive(_ gestureRecognizer: UIGestureRecognizer, touch: UITouch) -> Bool {
        if gestureRecognizer === interactionPan || gestureRecognizer === interactionTap {
            lastTouchType = touch.type
        }
        return true
    }

    fileprivate func interactionShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = pagePoint(of: gestureRecognizer)
        let isFinger = lastTouchType == .direct
        if gestureRecognizer === interactionPan {
            switch toolKind {
            case .lasso:
                if hasInkSelection && (overlay.handle(at: point) != nil || overlay.selectionContains(point)) { return true }
                return !isFinger || !fingerDrawingDisabled
            case .objects, .text:
                if selectedElement != nil, overlay.handle(at: point) != nil { return true }
                return element(at: point) != nil
            default:
                return false
            }
        }
        if gestureRecognizer === interactionTap {
            switch toolKind {
            case .text, .objects, .lasso: return true
            default:
                // While inking, only finger taps (that don't draw) may follow links.
                return isFinger && fingerDrawingDisabled && element(at: point)?.kind == .link
            }
        }
        if gestureRecognizer === undoTap || gestureRecognizer === redoTap {
            return true
        }
        return true
    }

    fileprivate func interactionShouldRecognizeSimultaneously(_ gestureRecognizer: UIGestureRecognizer,
                                                              with other: UIGestureRecognizer) -> Bool {
        // Multi-finger taps must coexist with the scroll view's pinch.
        (gestureRecognizer === undoTap || gestureRecognizer === redoTap) && other === canvas.pinchGestureRecognizer
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = pagePoint(of: gesture)
        // A tap (or a hold without moving) on a selection handle must never deselect;
        // the handles sit outside the selected object, so treat it as a no-op.
        if (hasInkSelection || selectedElement != nil), overlay.handle(at: point) != nil { return }
        let hit = element(at: point)
        switch toolKind {
        case .text:
            if let hit, hit.kind == .text {
                selectElement(hit.id)
                delegate?.canvasRequestsTextEditing(hit, isNew: false)
            } else if let hit, hit.kind == .link, let target = hit.targetPageID {
                delegate?.canvasDidActivateLink(to: target)
            } else if let page {
                let width = min(320, page.size.width - point.x - 20)
                let origin = CGPoint(x: min(point.x, page.size.width - 120), y: min(point.y - 14, page.size.height - 40))
                let element = PageElement.textBox(at: origin, width: max(width, 120))
                delegate?.canvasRequestsTextEditing(element, isNew: true)
            }
        case .objects:
            if let hit {
                if hit.id == selectedElementID {
                    if hit.kind == .text { delegate?.canvasRequestsTextEditing(hit, isNew: false) }
                    if hit.kind == .link, let target = hit.targetPageID { delegate?.canvasDidActivateLink(to: target) }
                } else {
                    selectElement(hit.id)
                }
            } else {
                clearElementSelection()
            }
        case .lasso:
            if !overlay.selectionContains(point) { clearInkSelection() }
        default:
            if let hit, hit.kind == .link, let target = hit.targetPageID {
                delegate?.canvasDidActivateLink(to: target)
            }
        }
    }

    @objc private func handleInteractionPan(_ gesture: UIPanGestureRecognizer) {
        let point = pagePoint(of: gesture)
        switch gesture.state {
        case .began:
            let location = gesture.location(in: canvas)
            let translation = gesture.translation(in: canvas)
            let touchDown = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            beginInteraction(at: pagePoint(fromCanvasPoint: touchDown))
            continueInteraction(at: point)
        case .changed:
            continueInteraction(at: point)
        case .ended:
            endInteraction(at: point, cancelled: false)
        case .cancelled, .failed:
            endInteraction(at: point, cancelled: true)
        default:
            break
        }
    }

    private func beginInteraction(at point: CGPoint) {
        setScrollingLocked(true)
        rotationSnapped = true   // no tick for the unrotated starting position
        snapFeedback.prepare()
        Log.editor.debug("interaction begin tool=\(self.toolKind.rawValue, privacy: .public) page=(\(point.x), \(point.y)) zoom=\(self.canvas.zoomScale)")
        switch toolKind {
        case .lasso:
            if hasInkSelection, let handle = overlay.handle(at: point) {
                beginInkTransform(handle == .scale ? .scale : .rotate, at: point)
            } else if hasInkSelection, overlay.selectionContains(point) {
                beginInkTransform(.move, at: point)
            } else {
                clearInkSelection()
                interaction = .lasso([point])
            }
        case .objects, .text:
            if let element = selectedElement, let handle = overlay.handle(at: point) {
                interaction = .transformElement(kind: handle == .scale ? .resize : .rotate, start: point, original: element)
            } else if let hit = element(at: point) {
                selectElement(hit.id)
                interaction = .transformElement(kind: .move, start: point, original: hit)
            }
        default:
            interaction = .none
        }
    }

    private func beginInkTransform(_ kind: InkTransformKind, at point: CGPoint) {
        let original = canvas.drawing
        let selected = selectedStrokes
        let bounds = selectionBounds
        guard !selected.isEmpty, !bounds.isNull else { return }
        // Render the selection once, then hide it from the live canvas while dragging.
        var image: UIImage?
        let scale = min(canvas.zoomScale * traitCollection.displayScale, 6)
        PageRenderer.lightTraits.performAsCurrent {
            image = PKDrawing(strokes: selected).image(from: bounds, scale: scale)
        }
        // A previous drag's pending preview hide must not remove this new preview.
        hidePreviewOnRender = false
        previewHideTask?.cancel()
        if let image { overlay.beginPreview(image: image, frame: bounds) }
        var remaining = original
        remaining.strokes = original.strokes.enumerated().filter { !selectedStrokeIndices.contains($0.offset) }.map(\.element)
        applyDrawing(remaining, notify: false)
        interaction = .transformInk(kind: kind, start: point, original: original, selected: selected, bounds: bounds)
    }

    private func inkTransform(kind: InkTransformKind, start: CGPoint, current: CGPoint, bounds: CGRect) -> CGAffineTransform {
        switch kind {
        case .move:
            return CGAffineTransform(translationX: current.x - start.x, y: current.y - start.y)
        case .scale:
            let anchor = CGPoint(x: bounds.minX, y: bounds.minY)
            let startDistance = max(start.distance(to: anchor), 1)
            let factor = min(max(current.distance(to: anchor) / startDistance, 0.1), 10)
            return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                .concatenating(CGAffineTransform(scaleX: factor, y: factor))
                .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        case .rotate:
            let center = bounds.center
            let angle = snapRotation(atan2(current.y - center.y, current.x - center.x) - atan2(start.y - center.y, start.x - center.x))
            return CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        }
    }

    private func continueInteraction(at point: CGPoint) {
        switch interaction {
        case .lasso(var points):
            if let last = points.last, last.distance(to: point) > 1.5 / canvas.zoomScale {
                points.append(point)
                interaction = .lasso(points)
                overlay.showLasso(points)
            }
        case .transformInk(let kind, let start, _, _, let bounds):
            let transform = inkTransform(kind: kind, start: start, current: point, bounds: bounds)
            overlay.updatePreview(transform: transform)
            let framePath = bounds.insetBy(dx: -6, dy: -6)
            if kind == .rotate {
                let angle = atan2(transform.b, transform.a)
                overlay.showSelection(frame: framePath, rotation: angle)
            } else {
                overlay.showSelection(frame: framePath.applying(transform))
            }
        case .transformElement(let kind, let start, let original):
            var element = original
            switch kind {
            case .move:
                element.frame = original.frame.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            case .resize:
                element = resized(original, draggingCornerTo: point)
            case .rotate:
                let center = original.frame.center
                let angle = atan2(point.y - center.y, point.x - center.x) + .pi / 2
                element.rotation = Double(snapRotation(angle))
            }
            underlay.preview(element)
            overlay.showSelection(frame: element.frame, rotation: CGFloat(element.rotation))
        case .none:
            break
        }
    }

    private func endInteraction(at point: CGPoint, cancelled: Bool) {
        setScrollingLocked(false)
        Log.editor.debug("interaction end page=(\(point.x), \(point.y)) cancelled=\(cancelled)")
        let current = interaction
        interaction = .none
        switch current {
        case .lasso(let points):
            overlay.clearLasso()
            guard !cancelled, points.count > 3 else { return }
            selectStrokes(StrokeTools.strokesInside(points, drawing: canvas.drawing))
        case .transformInk(let kind, let start, let original, let selected, let bounds):
            // The preview stays visible until PencilKit has drawn the committed strokes
            // (rendering is asynchronous), so the ink never flashes at its old position.
            hidePreviewAfterNextRender()
            if cancelled {
                overlay.updatePreview(transform: .identity)
                applyDrawing(original, notify: false)
                selectStrokes(selectedStrokeIndices)
                return
            }
            let transform = inkTransform(kind: kind, start: start, current: point, bounds: bounds)
            var final = canvas.drawing   // drawing without the selection
            let startIndex = final.strokes.count
            final.strokes.append(contentsOf: selected.map { StrokeTools.transformed($0, by: transform) })
            // One update straight to the result; undo returns to the pre-drag drawing.
            setDrawing(final, actionName: kind == .move ? "Move" : (kind == .scale ? "Resize" : "Rotate"),
                       previous: original)
            selectStrokes(IndexSet(startIndex..<final.strokes.count))
        case .transformElement(_, _, let original):
            guard let edited = currentPreview(for: original.id) else { return }
            if cancelled || edited == original {
                underlay.preview(original)
                overlay.showSelection(frame: original.frame, rotation: CGFloat(original.rotation))
                return
            }
            var all = elements
            if let index = all.firstIndex(where: { $0.id == original.id }) { all[index] = edited }
            setElements(all, actionName: "Move")
        case .none:
            break
        }
    }

    /// Resizes from the bottom-right handle while the element's top-left corner stays put,
    /// also when rotated. Images keep their aspect ratio; text scales its font with the box.
    private func resized(_ original: PageElement, draggingCornerTo point: CGPoint) -> PageElement {
        var element = original
        let angle = CGFloat(original.rotation)
        let frame = original.frame
        // Fixed anchor: the top-left corner in page coordinates (after rotation).
        let anchor = rotate(CGPoint(x: frame.minX, y: frame.minY), around: frame.center, by: angle)
        // Drag position expressed in the element's own (unrotated) axes, relative to the anchor.
        let local = rotate(point, around: anchor, by: -angle) - anchor
        var size: CGSize
        switch original.kind {
        case .image:
            let width = max(local.x, 40)
            size = CGSize(width: width, height: width * frame.height / max(frame.width, 1))
        case .text, .link:
            let factor = min(max(local.x / max(frame.width, 1), 0.2), 8)
            element.fontSize = min(max(original.fontSize * Double(factor), 6), 200)
            element.frame.size.width = max(frame.width * factor, 40)
            size = CGSize(width: element.frame.width,
                          height: original.kind == .text ? ElementStyle.fittingHeight(for: element) : frame.height * factor)
        }
        size.height = max(size.height, 20)
        // Place the new frame so its rotated top-left corner coincides with the anchor.
        let halfDiagonal = rotate(CGPoint(x: size.width / 2, y: size.height / 2), around: .zero, by: angle)
        let center = anchor + halfDiagonal
        element.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height)
        return element
    }

    /// While moving/resizing, the page must not scroll or zoom under the finger.
    private func setScrollingLocked(_ locked: Bool) {
        canvas.isScrollEnabled = !locked
        canvas.pinchGestureRecognizer?.isEnabled = !locked
    }

    private func currentPreview(for id: UUID) -> PageElement? {
        underlay.elementsContainer.subviews.compactMap { $0 as? ElementView }.first { $0.element.id == id }?.element
    }

    private func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let d = point - center
        return CGPoint(x: center.x + d.x * cos(angle) - d.y * sin(angle), y: center.y + d.x * sin(angle) + d.y * cos(angle))
    }

    /// Snaps rotation to multiples of 15° when close.
    /// Whether the current rotation is locked onto a right angle (for the haptic tick).
    private var rotationSnapped = false
    private let snapFeedback = UISelectionFeedbackGenerator()

    /// Locks rotation onto 0°, 90°, 180° and 270° when within ~8°, with a haptic tick on entry.
    private func snapRotation(_ angle: CGFloat) -> CGFloat {
        let rightAngle = CGFloat.pi / 2
        let nearest = (angle / rightAngle).rounded() * rightAngle
        let snapped = abs(angle - nearest) < .pi / 22
        if snapped && !rotationSnapped { snapFeedback.selectionChanged() }
        rotationSnapped = snapped
        return snapped ? nearest : angle
    }

    // MARK: UIPencilInteractionDelegate

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        delegate?.canvasPencilDoubleTapped()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { delegate?.canvasPencilSqueezed() }
    }
}
