import UIKit
import os

/// CATiledLayer without the default fade-in, so zooming never flashes.
final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// Draws the paper template and the original PDF page. Uses tiles so only the visible
/// region is rendered, and re-renders at higher detail when zoomed (crisp vector PDFs).
final class TiledPageBackgroundView: UIView {
    nonisolated struct RenderState: Sendable {
        var style = PageStyle.default
        var size = CGSize(width: 612, height: 792)
        var pdfURL: URL?
        var pdfPageIndex = 0
    }

    override class var layerClass: AnyClass { InstantTiledLayer.self }

    /// Read from CATiledLayer's background threads, so it lives behind a lock.
    private let state = OSAllocatedUnfairLock(initialState: RenderState())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        if let tiled = layer as? CATiledLayer {
            tiled.levelsOfDetail = 4
            tiled.levelsOfDetailBias = 4
            tiled.tileSize = CGSize(width: 1024, height: 1024)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ newState: RenderState) {
        state.withLock { $0 = newState }
        // Tiles render asynchronously; show the paper colour (not the desk) until they arrive.
        backgroundColor = UIColor(hex: newState.style.backgroundColorHex)
        layer.contents = nil
        layer.setNeedsDisplay()
    }

    nonisolated override func draw(_ layer: CALayer, in ctx: CGContext) {
        let snapshot = state.withLock { $0 }
        PageBackgroundRenderer.draw(snapshot.style, size: snapshot.size, in: ctx)
        if let url = snapshot.pdfURL,
           let page = PDFDocumentCache.shared.page(url: url, index: snapshot.pdfPageIndex) {
            PageRenderer.drawPDFPage(page, in: CGRect(origin: .zero, size: snapshot.size), ctx: ctx)
        }
    }
}

/// On-screen representation of a text box, image or link.
final class ElementView: UIView {
    private(set) var element: PageElement
    private let imageView = UIImageView()
    private let assetURL: (String) -> URL
    private var loadedAssetName: String?
    private var loadTask: Task<Void, Never>?

    init(element: PageElement, assetURL: @escaping (String) -> URL) {
        self.element = element
        self.assetURL = assetURL
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        apply(element)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ element: PageElement) {
        self.element = element
        transform = .identity
        bounds = CGRect(origin: .zero, size: element.frame.size)
        center = element.frame.center
        transform = CGAffineTransform(rotationAngle: CGFloat(element.rotation))
        imageView.frame = bounds
        imageView.isHidden = element.kind != .image
        isAccessibilityElement = true
        switch element.kind {
        case .text: accessibilityLabel = element.text; accessibilityTraits = .staticText
        case .image: accessibilityLabel = "Image"; accessibilityTraits = .image
        case .link: accessibilityLabel = "Link to \(element.text)"; accessibilityTraits = .link
        }
        if element.kind == .image, let name = element.assetName, name != loadedAssetName {
            loadImage(named: name)
        }
        setNeedsDisplay()
    }

    /// Images are decoded off the main thread and downsampled to the display size.
    private func loadImage(named name: String) {
        loadedAssetName = name
        loadTask?.cancel()
        let url = assetURL(name)
        let maxPixel = max(element.frame.width, element.frame.height) * 3
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ImageLoader.downsampledImage(at: url, maxPixelSize: min(maxPixel, 3000))
            }.value
            guard !Task.isCancelled else { return }
            self?.imageView.image = image
        }
    }

    override func draw(_ rect: CGRect) {
        guard element.kind != .image, let ctx = UIGraphicsGetCurrentContext() else { return }
        var local = element
        local.frame.origin = .zero
        local.rotation = 0
        PageRenderer.drawElement(local, assetURL: assetURL, options: PageRenderOptions(), in: ctx)
    }
}

/// Page-sized container placed *under* the PencilKit ink. Its bounds are the page in
/// points; zoom is applied with a transform so ink and paper always line up.
final class PageUnderlayView: UIView {
    let background = TiledPageBackgroundView()
    let elementsContainer = UIView()
    private var elementViews: [UUID: ElementView] = [:]
    var assetURL: (String) -> URL = { URL(fileURLWithPath: $0) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.anchorPoint = .zero
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(background)
        addSubview(elementsContainer)
        elementsContainer.clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(state: TiledPageBackgroundView.RenderState) {
        let rect = CGRect(origin: .zero, size: state.size)
        let currentTransform = transform
        transform = .identity
        bounds = rect
        layer.position = .zero
        transform = currentTransform
        background.frame = rect
        elementsContainer.frame = rect
        layer.shadowPath = UIBezierPath(rect: rect).cgPath
        background.configure(state)
    }

    func setZoom(_ zoom: CGFloat) {
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
        layer.position = .zero
    }

    func setElements(_ elements: [PageElement]) {
        let ids = Set(elements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
        }
        for element in elements {
            if let view = elementViews[element.id] {
                if view.element != element { view.apply(element) }
                elementsContainer.bringSubviewToFront(view)
            } else {
                let view = ElementView(element: element, assetURL: assetURL)
                elementViews[element.id] = view
                elementsContainer.addSubview(view)
            }
        }
    }

    /// Lightweight live update used while dragging/resizing.
    func preview(_ element: PageElement) {
        elementViews[element.id]?.apply(element)
    }

    /// Re-renders text at the current zoom so it stays sharp.
    func updateRenderScale(_ scale: CGFloat) {
        let capped = min(scale, traitCollection.displayScale * 6)
        for view in elementViews.values where view.element.kind != .image {
            if abs(view.contentScaleFactor - capped) > 0.01 {
                view.contentScaleFactor = capped
                view.setNeedsDisplay()
            }
        }
    }
}
