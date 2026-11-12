import SwiftData
import Testing
import Foundation
import PencilKit
import UIKit
@testable import MyApp

@Suite("Shape recognition & strokes")
struct ShapeRecognitionTests {
    private func jitter(_ points: [CGPoint], amount: CGFloat = 1.5) -> [CGPoint] {
        points.enumerated().map { i, p in
            CGPoint(x: p.x + sin(CGFloat(i) * 1.7) * amount, y: p.y + cos(CGFloat(i) * 2.3) * amount)
        }
    }

    private func polyline(_ corners: [CGPoint], step: CGFloat = 3) -> [CGPoint] {
        StrokeTools.densify(corners, spacing: step)
    }

    @Test func recognizesLineAndSnapsHorizontal() throws {
        let points = jitter(polyline([CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 203)]))
        let shape = try #require(ShapeRecognizer.recognize(points))
        guard case .line(let a, let b) = shape else { Issue.record("Expected line, got \(shape.name)"); return }
        #expect(abs(a.y - b.y) < 0.01, "Nearly horizontal lines snap exactly horizontal")
    }

    @Test func recognizesCircle() throws {
        let points = (0...80).map { i -> CGPoint in
            let t = CGFloat(i) / 80 * 2 * .pi
            return CGPoint(x: 300 + 100 * cos(t), y: 300 + 96 * sin(t))
        }
        let shape = try #require(ShapeRecognizer.recognize(jitter(points)))
        guard case .ellipse(let rect) = shape else { Issue.record("Expected ellipse, got \(shape.name)"); return }
        #expect(abs(rect.width - rect.height) < 0.01, "Near-circles become perfect circles")
    }

    @Test func recognizesRectangle() throws {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 104), CGPoint(x: 398, y: 300),
                       CGPoint(x: 102, y: 296), CGPoint(x: 100, y: 102)]
        let shape = try #require(ShapeRecognizer.recognize(jitter(polyline(corners))))
        guard case .rectangle(let points) = shape else { Issue.record("Expected rectangle, got \(shape.name)"); return }
        #expect(points.count == 4)
        let box = PolygonMath.boundingBox(points)
        #expect(abs(box.width - 300) < 12 && abs(box.height - 200) < 12)
    }

    @Test func recognizesTriangle() throws {
        let corners = [CGPoint(x: 200, y: 100), CGPoint(x: 350, y: 350), CGPoint(x: 50, y: 350), CGPoint(x: 199, y: 104)]
        let shape = try #require(ShapeRecognizer.recognize(jitter(polyline(corners))))
        guard case .triangle(let points) = shape else { Issue.record("Expected triangle, got \(shape.name)"); return }
        #expect(points.count == 3)
    }

    @Test func recognizesArrow() throws {
        // Shaft to the right, then a barb back down-left from the tip.
        let points = polyline([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 370, y: 330)])
        let shape = try #require(ShapeRecognizer.recognize(jitter(points, amount: 0.8)))
        guard case .arrow(let tail, let tip) = shape else { Issue.record("Expected arrow, got \(shape.name)"); return }
        #expect(tail.x < tip.x)
        #expect(shape.polylines.count == 2, "Arrow = shaft + head")
    }

    @Test func ignoresScribblesAndTinyStrokes() {
        let scribble = (0..<120).map { i in CGPoint(x: 100 + CGFloat(i) * 2, y: 200 + (i % 2 == 0 ? 0 : 40)) }
        #expect(ShapeRecognizer.recognize(scribble) == nil)
        #expect(ShapeRecognizer.recognize([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5)]) == nil)
        #expect(ShapeRecognizer.recognize([]) == nil)
    }

    @Test func shapeStrokesKeepInkAndWidth() {
        let original = TestInk.stroke(points: polyline([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]), color: .red, width: 6)
        let strokes = StrokeTools.strokes(for: .line(.zero, CGPoint(x: 200, y: 0)), like: original)
        #expect(strokes.count == 1)
        #expect(strokes[0].ink.inkType == original.ink.inkType)
        #expect(abs((strokes[0].path.first?.size.width ?? 0) - 6) < 0.5)
    }

    @Test func lassoSelectsEnclosedStrokesOnly() {
        let inside = TestInk.stroke(y: 150, from: 120, to: 180)
        let outside = TestInk.stroke(y: 400, from: 120, to: 180)
        let drawing = PKDrawing(strokes: [inside, outside])
        let lasso = [CGPoint(x: 100, y: 100), CGPoint(x: 220, y: 100), CGPoint(x: 220, y: 200), CGPoint(x: 100, y: 200)]
        #expect(StrokeTools.strokesInside(lasso, drawing: drawing) == IndexSet(integer: 0))
    }

    @Test func transformAndRecolorStrokes() {
        let stroke = TestInk.stroke(y: 100, from: 0, to: 100)
        let moved = StrokeTools.transformed(stroke, by: CGAffineTransform(translationX: 50, y: 20))
        #expect(abs(moved.renderBounds.minX - stroke.renderBounds.minX - 50) < 0.5)
        let recolored = StrokeTools.recolored(stroke, color: .blue)
        #expect(recolored.ink.color.hexString == UIColor.blue.hexString)
        #expect(recolored.path.count == stroke.path.count, "Recolor never changes geometry")
    }

    @Test func scalingBakesGeometrySoBoundsMatchRendering() {
        let stroke = TestInk.stroke(points: StrokeTools.densify([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300)], spacing: 4), width: 4)
        let anchor = CGPoint(x: 100, y: 100)
        let half = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: 0.5, y: 0.5))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        let scaled = StrokeTools.transformed(stroke, by: half)
        #expect(scaled.transform == .identity, "Geometry is baked into the points")
        // Points moved to the scaled positions and the ink got thinner.
        let last = scaled.path.last?.location ?? .zero
        #expect(abs(last.x - 200) < 0.5 && abs(last.y - 200) < 0.5)
        #expect(abs((scaled.path.first?.size.width ?? 0) - 2) < 0.01)
        // The bounds used for selection now describe the drawn stroke.
        let bounds = scaled.renderBounds
        #expect(abs(bounds.midX - 150) < 3 && abs(bounds.midY - 150) < 3)
        #expect(bounds.width < 110, "Bounds shrink with the stroke (was \(bounds.width))")
        // Repeated transforms stay consistent.
        let back = StrokeTools.transformed(scaled, by: half.inverted())
        #expect(abs((back.path.last?.location.x ?? 0) - 300) < 0.5)
    }

    @Test func endHoldDurationDetectsPause() {
        var points = (0..<50).map { CGPoint(x: CGFloat($0) * 4, y: 0) }
        points += Array(repeating: CGPoint(x: 196, y: 0), count: 60)   // 0.6 s at 10 ms per point
        let stroke = TestInk.stroke(points: points)
        #expect(StrokeTools.endHoldDuration(of: stroke) > 0.45)
        #expect(StrokeTools.endHoldDuration(of: TestInk.stroke()) < 0.1)
    }
}

@Suite("Rendering")
struct RenderingTests {
    /// Fraction of pixels that are noticeably darker than white.
    private func inkCoverage(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 600 {
            dark += 1
        }
        return Double(dark) / Double(width * height)
    }

    private func snapshot(_ style: PageStyle) -> PageRenderSnapshot {
        PageRenderSnapshot(pageID: UUID(), size: style.pageSize, style: style, pdfURL: nil, pdfPageIndex: 0, contentVersion: 0)
    }

    @Test func templatesDrawLinesButBlankStaysEmpty() {
        let blank = PageRenderer.image(snapshot(PageStyle(template: .blank)), content: .empty, assetURL: { URL(fileURLWithPath: $0) }, pixelWidth: 300)
        #expect(inkCoverage(blank) == 0)
        for template in PaperTemplate.allCases where template != .blank {
            var style = PageStyle(template: template)
            style.lineColorHex = "#000000"
            let image = PageRenderer.image(snapshot(style), content: .empty, assetURL: { URL(fileURLWithPath: $0) }, pixelWidth: 600)
            #expect(inkCoverage(image) > 0.001, "\(template.displayName) should draw something")
        }
    }

    @Test func inkIsRenderedInLightModeColors() {
        let content = PageContent(drawing: PKDrawing(strokes: [TestInk.stroke(points: StrokeTools.densify(
            [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 600)], spacing: 3), color: .black, width: 30)]), elements: [])
        let image = PageRenderer.image(snapshot(PageStyle(template: .blank)), content: content,
                                       assetURL: { URL(fileURLWithPath: $0) }, pixelWidth: 612)
        #expect(inkCoverage(image) > 0.01, "Black ink must stay dark on white paper")
    }

    @Test func elementHitTestingHonorsRotation() {
        var element = PageElement.textBox(at: CGPoint(x: 100, y: 100), width: 200)
        element.frame.size.height = 20
        #expect(element.contains(CGPoint(x: 290, y: 110)))
        element.rotation = .pi / 2
        #expect(!element.contains(CGPoint(x: 290, y: 110)), "Rotated 90° the far right end is no longer inside")
        #expect(element.contains(CGPoint(x: 200, y: 190)))
    }

    @Test func colorHexRoundTrip() {
        #expect(UIColor(hex: "#2F6FEB").hexString == "#2F6FEB")
        #expect(UIColor(hex: "#FF000080").hexString == "#FF000080")
    }
}
