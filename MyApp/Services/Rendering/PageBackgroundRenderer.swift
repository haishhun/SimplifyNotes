import UIKit

/// Draws paper templates with Core Graphics. Used by the live canvas (tiled layer),
/// thumbnails and PDF export so every surface looks identical.
/// The context must use a top-left origin with page-point units.
nonisolated enum PageBackgroundRenderer {
    static let marginColor = UIColor(red: 0.91, green: 0.55, blue: 0.55, alpha: 0.75).cgColor

    static func draw(_ style: PageStyle, size: CGSize, in ctx: CGContext, fillBackground: Bool = true) {
        let pageRect = CGRect(origin: .zero, size: size)
        // Restrict work to the dirty region; essential for tiled rendering when zoomed in.
        let clip = ctx.boundingBoxOfClipPath.intersection(pageRect)
        guard !clip.isNull, !clip.isEmpty else { return }

        if fillBackground {
            ctx.setFillColor(UIColor(hex: style.backgroundColorHex).cgColor)
            ctx.fill(clip)
        }

        let lineColor = UIColor(hex: style.lineColorHex).cgColor
        let spacing = max(CGFloat(style.spacing), 2)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(lineColor)
        ctx.setFillColor(lineColor)

        switch style.template {
        case .blank:
            break
        case .collegeRuled, .wideRuled:
            drawRuled(size: size, top: CGFloat(style.marginTop), spacing: spacing, clip: clip, ctx: ctx)
            let x = CGFloat(style.marginLeft)
            if x > 0, x < size.width, clip.minX <= x, clip.maxX >= x {
                ctx.setStrokeColor(marginColor)
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: x, y: max(clip.minY, 0)))
                ctx.addLine(to: CGPoint(x: x, y: min(clip.maxY, size.height)))
                ctx.strokePath()
            }
        case .grid:
            drawGrid(size: size, spacing: spacing, clip: clip, lineWidth: 0.5, majorEvery: 0, ctx: ctx)
        case .graph:
            drawGrid(size: size, spacing: spacing, clip: clip, lineWidth: 0.3, majorEvery: 5, ctx: ctx)
        case .dotted:
            drawDots(size: size, spacing: spacing, clip: clip, ctx: ctx)
        case .cornell:
            drawCornell(style: style, size: size, spacing: spacing, clip: clip, ctx: ctx)
        case .music:
            drawMusic(style: style, size: size, gap: spacing, clip: clip, ctx: ctx)
        }
    }

    private static func visibleRange(start: CGFloat, step: CGFloat, from: CGFloat, to: CGFloat) -> StrideThrough<CGFloat> {
        let first = start + max(0, ((from - start) / step).rounded(.down)) * step
        return stride(from: first, through: to, by: step)
    }

    private static func drawRuled(size: CGSize, top: CGFloat, spacing: CGFloat, clip: CGRect, ctx: CGContext) {
        ctx.setLineWidth(0.6)
        let bottomLimit = min(size.height - spacing * 0.5, clip.maxY)
        for y in visibleRange(start: top, step: spacing, from: clip.minY, to: bottomLimit) where y >= top {
            ctx.move(to: CGPoint(x: clip.minX, y: y))
            ctx.addLine(to: CGPoint(x: clip.maxX, y: y))
        }
        ctx.strokePath()
    }

    private static func drawGrid(size: CGSize, spacing: CGFloat, clip: CGRect, lineWidth: CGFloat, majorEvery: Int, ctx: CGContext) {
        let offsetX = size.width.truncatingRemainder(dividingBy: spacing) / 2
        let offsetY = size.height.truncatingRemainder(dividingBy: spacing) / 2
        func isMajor(_ value: CGFloat, offset: CGFloat) -> Bool {
            guard majorEvery > 0 else { return false }
            return Int(((value - offset) / spacing).rounded()) % majorEvery == 0
        }
        // Minor lines
        ctx.setLineWidth(lineWidth)
        for x in visibleRange(start: offsetX, step: spacing, from: clip.minX, to: clip.maxX) where !isMajor(x, offset: offsetX) {
            ctx.move(to: CGPoint(x: x, y: clip.minY)); ctx.addLine(to: CGPoint(x: x, y: clip.maxY))
        }
        for y in visibleRange(start: offsetY, step: spacing, from: clip.minY, to: clip.maxY) where !isMajor(y, offset: offsetY) {
            ctx.move(to: CGPoint(x: clip.minX, y: y)); ctx.addLine(to: CGPoint(x: clip.maxX, y: y))
        }
        ctx.strokePath()
        guard majorEvery > 0 else { return }
        // Major lines
        ctx.setLineWidth(lineWidth * 2.6)
        for x in visibleRange(start: offsetX, step: spacing, from: clip.minX, to: clip.maxX) where isMajor(x, offset: offsetX) {
            ctx.move(to: CGPoint(x: x, y: clip.minY)); ctx.addLine(to: CGPoint(x: x, y: clip.maxY))
        }
        for y in visibleRange(start: offsetY, step: spacing, from: clip.minY, to: clip.maxY) where isMajor(y, offset: offsetY) {
            ctx.move(to: CGPoint(x: clip.minX, y: y)); ctx.addLine(to: CGPoint(x: clip.maxX, y: y))
        }
        ctx.strokePath()
    }

    private static func drawDots(size: CGSize, spacing: CGFloat, clip: CGRect, ctx: CGContext) {
        // Keep dots at least ~1 device pixel wide so small previews don't lose them.
        let deviceScale = max(ctx.convertToDeviceSpace(CGSize(width: 1, height: 0)).width.magnitude, 0.01)
        let radius = max(0.9, 0.75 / deviceScale)
        let offsetX = size.width.truncatingRemainder(dividingBy: spacing) / 2
        let offsetY = size.height.truncatingRemainder(dividingBy: spacing) / 2
        for y in visibleRange(start: offsetY, step: spacing, from: clip.minY - radius, to: clip.maxY + radius) {
            for x in visibleRange(start: offsetX, step: spacing, from: clip.minX - radius, to: clip.maxX + radius) {
                ctx.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        ctx.fillPath()
    }

    /// Layout for Cornell notes: title band, cue column, notes area and summary band.
    static func cornellLayout(style: PageStyle, size: CGSize) -> (headerBottom: CGFloat, cueX: CGFloat, summaryTop: CGFloat) {
        let header = max(CGFloat(style.marginTop), 36)
        let cue = min(max(CGFloat(style.marginLeft) * 2, size.width * 0.28), size.width * 0.45)
        let summary = size.height - size.height * 0.2
        return (header, cue, summary)
    }

    private static func drawCornell(style: PageStyle, size: CGSize, spacing: CGFloat, clip: CGRect, ctx: CGContext) {
        let layout = cornellLayout(style: style, size: size)
        // Faint ruling inside notes + cue areas
        ctx.setLineWidth(0.5)
        for y in visibleRange(start: layout.headerBottom + spacing, step: spacing, from: clip.minY, to: min(layout.summaryTop - 4, clip.maxY)) {
            ctx.move(to: CGPoint(x: clip.minX, y: y)); ctx.addLine(to: CGPoint(x: clip.maxX, y: y))
        }
        ctx.strokePath()
        // Structure lines
        ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: 0, y: layout.headerBottom)); ctx.addLine(to: CGPoint(x: size.width, y: layout.headerBottom))
        ctx.move(to: CGPoint(x: layout.cueX, y: layout.headerBottom)); ctx.addLine(to: CGPoint(x: layout.cueX, y: layout.summaryTop))
        ctx.move(to: CGPoint(x: 0, y: layout.summaryTop)); ctx.addLine(to: CGPoint(x: size.width, y: layout.summaryTop))
        ctx.strokePath()
    }

    private static func drawMusic(style: PageStyle, size: CGSize, gap: CGFloat, clip: CGRect, ctx: CGContext) {
        let side: CGFloat = 36
        let staffHeight = gap * 4
        let staffPitch = staffHeight + gap * 6
        ctx.setLineWidth(0.6)
        var top = CGFloat(style.marginTop)
        while top + staffHeight <= size.height - side {
            if top + staffHeight >= clip.minY && top <= clip.maxY {
                for line in 0..<5 {
                    let y = top + CGFloat(line) * gap
                    ctx.move(to: CGPoint(x: side, y: y)); ctx.addLine(to: CGPoint(x: size.width - side, y: y))
                }
                // Bar lines at both ends
                ctx.move(to: CGPoint(x: side, y: top)); ctx.addLine(to: CGPoint(x: side, y: top + staffHeight))
                ctx.move(to: CGPoint(x: size.width - side, y: top)); ctx.addLine(to: CGPoint(x: size.width - side, y: top + staffHeight))
            }
            top += staffPitch
        }
        ctx.strokePath()
    }
}
