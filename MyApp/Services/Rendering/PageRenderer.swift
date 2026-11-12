import UIKit
import PencilKit
import ImageIO

/// Immutable description of a page for off-main-thread rendering.
nonisolated struct PageRenderSnapshot: Sendable, Hashable {
    let pageID: UUID
    let size: CGSize
    let style: PageStyle
    let pdfURL: URL?
    let pdfPageIndex: Int
    let contentVersion: Int
}

extension Page {
    func renderSnapshot(store: PageContentStoring) -> PageRenderSnapshot {
        PageRenderSnapshot(pageID: id, size: size, style: style,
                           pdfURL: pdfFileName.map { store.pdfURL(named: $0) },
                           pdfPageIndex: pdfPageIndex, contentVersion: contentVersion)
    }
}

nonisolated struct PageRenderOptions: Sendable {
    var includeBackground = true
    var includePDF = true
    /// Pixel density used to rasterise ink.
    var inkScale: CGFloat = 3
    /// Max pixel size for images (nil = original resolution).
    var maxImagePixelSize: CGFloat?
}

/// Thread-safe cache of opened PDF documents.
nonisolated final class PDFDocumentCache: @unchecked Sendable {
    static let shared = PDFDocumentCache()
    private let cache = NSCache<NSURL, CGPDFDocument>()

    init() { cache.countLimit = 8 }

    func document(at url: URL) -> CGPDFDocument? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        cache.setObject(document, forKey: url as NSURL)
        return document
    }

    func page(url: URL, index: Int) -> CGPDFPage? {
        document(at: url)?.page(at: index + 1)
    }
}

/// Fonts and colours shared by on-screen element views and offline rendering.
nonisolated enum ElementStyle {
    static func font(for element: PageElement) -> UIFont {
        let base = UIFont.systemFont(ofSize: CGFloat(element.fontSize), weight: element.kind == .link ? .semibold : .regular)
        let design: UIFontDescriptor.SystemDesign
        switch element.fontDesign {
        case .standard: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .monospaced: design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: CGFloat(element.fontSize))
    }

    static func attributedText(for element: PageElement) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = element.kind == .link ? "→ " + element.text : element.text
        return NSAttributedString(string: text, attributes: [
            .font: font(for: element),
            .foregroundColor: UIColor(hex: element.colorHex),
            .paragraphStyle: paragraph
        ])
    }

    /// Height needed to show the text at the element's width.
    static func fittingHeight(for element: PageElement) -> CGFloat {
        let insets: CGFloat = 12
        let bounds = attributedText(for: element).boundingRect(
            with: CGSize(width: max(element.frame.width - insets, 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return max(ceil(bounds.height) + insets, CGFloat(element.fontSize) + insets)
    }

    static let textInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
}

nonisolated enum ImageLoader {
    /// Memory-efficient downsampling through ImageIO (never decodes the full image).
    static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Composites a page: background → original PDF → images/text → ink.
nonisolated enum PageRenderer {
    static let lightTraits = UITraitCollection(userInterfaceStyle: .light)

    /// Draws into `ctx` in page coordinates (top-left origin). Callers set up scaling.
    static func draw(_ snapshot: PageRenderSnapshot,
                     content: PageContent,
                     assetURL: (String) -> URL,
                     options: PageRenderOptions,
                     in ctx: CGContext) {
        let rect = CGRect(origin: .zero, size: snapshot.size)
        ctx.saveGState()
        ctx.clip(to: rect)

        if options.includeBackground {
            PageBackgroundRenderer.draw(snapshot.style, size: snapshot.size, in: ctx)
        } else {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
        }

        if options.includePDF, let url = snapshot.pdfURL,
           let pdfPage = PDFDocumentCache.shared.page(url: url, index: snapshot.pdfPageIndex) {
            drawPDFPage(pdfPage, in: rect, ctx: ctx)
        }

        UIGraphicsPushContext(ctx)
        for element in content.elements {
            drawElement(element, assetURL: assetURL, options: options, in: ctx)
        }

        if !content.drawing.strokes.isEmpty {
            var inkImage: UIImage?
            // Render with light traits so dark-mode ink adaptation never leaks into output.
            lightTraits.performAsCurrent {
                inkImage = content.drawing.image(from: rect, scale: options.inkScale)
            }
            inkImage?.draw(in: rect)
        }
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    /// Draws a PDF page so it fills `rect` (top-left origin context).
    static func drawPDFPage(_ page: CGPDFPage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let target = CGRect(origin: .zero, size: rect.size)
        let box = page.getBoxRect(.cropBox)
        let rotation = Int(page.rotationAngle)
        let rotated = abs(rotation) % 180 == 90
        let visible = rotated ? CGSize(width: box.height, height: box.width) : box.size
        // getDrawingTransform never scales up, so compute an explicit fit scale.
        let scale = min(target.width / max(visible.width, 1), target.height / max(visible.height, 1))
        ctx.translateBy(x: target.midX, y: target.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    static func drawElement(_ element: PageElement, assetURL: (String) -> URL, options: PageRenderOptions, in ctx: CGContext) {
        ctx.saveGState()
        let frame = element.frame
        ctx.translateBy(x: frame.midX, y: frame.midY)
        ctx.rotate(by: CGFloat(element.rotation))
        let local = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
        switch element.kind {
        case .image:
            if let name = element.assetName {
                let url = assetURL(name)
                let image: UIImage?
                if let maxPixel = options.maxImagePixelSize {
                    image = ImageLoader.downsampledImage(at: url, maxPixelSize: maxPixel)
                } else {
                    image = UIImage(contentsOfFile: url.path)
                }
                image?.draw(in: local)
            }
        case .text:
            ElementStyle.attributedText(for: element)
                .draw(with: local.inset(by: ElementStyle.textInset), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        case .link:
            let pill = UIBezierPath(roundedRect: local, cornerRadius: min(local.height / 2, 12))
            UIColor(hex: element.colorHex).withAlphaComponent(0.12).setFill()
            pill.fill()
            ElementStyle.attributedText(for: element)
                .draw(with: local.inset(by: UIEdgeInsets(top: 8, left: 12, bottom: 6, right: 12)),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
        ctx.restoreGState()
    }

    /// Renders a page to an image (thumbnails, recognition).
    static func image(_ snapshot: PageRenderSnapshot, content: PageContent, assetURL: (String) -> URL,
                      pixelWidth: CGFloat, options: PageRenderOptions = PageRenderOptions()) -> UIImage {
        let scale = pixelWidth / max(snapshot.size.width, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let pixelSize = CGSize(width: (snapshot.size.width * scale).rounded(), height: (snapshot.size.height * scale).rounded())
        var opts = options
        opts.inkScale = max(scale, 0.25)
        opts.maxImagePixelSize = opts.maxImagePixelSize ?? max(pixelSize.width, pixelSize.height)
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(snapshot, content: content, assetURL: assetURL, options: opts, in: context.cgContext)
        }
    }
}
