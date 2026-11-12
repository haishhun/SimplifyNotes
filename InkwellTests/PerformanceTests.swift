import XCTest
import PencilKit
@testable import MyApp

/// Baselines for the expensive paths. Simulator numbers are only indicative;
/// record baselines on real iPad hardware (see README → Performance).
@MainActor
final class PerformanceTests: XCTestCase {
    /// A dense lecture page: ~3 000 handwriting strokes.
    private let heavyDrawing = PKDrawing(strokes: (0..<3_000).map { i in
        let x = CGFloat(i % 60) * 9 + 30, y = CGFloat(i / 60) * 14 + 40
        return TestInk.stroke(points: (0..<12).map { CGPoint(x: x + CGFloat($0), y: y + sin(CGFloat($0)) * 3) })
    })

    func testHeavyPageSerialization() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let data = heavyDrawing.dataRepresentation()
            _ = try? PKDrawing(data: data)
        }
    }

    func testThumbnailRendering() {
        let snapshot = PageRenderSnapshot(pageID: UUID(), size: CGSize(width: 612, height: 792), style: PageStyle(template: .grid),
                                          pdfURL: nil, pdfPageIndex: 0, contentVersion: 0)
        let content = PageContent(drawing: heavyDrawing, elements: [])
        measure(metrics: [XCTClockMetric()]) {
            _ = PageRenderer.image(snapshot, content: content, assetURL: { URL(fileURLWithPath: $0) }, pixelWidth: 300)
        }
    }

    func testExportTwentyHeavyPages() throws {
        let lib = try TestLibrary()
        let notebook = try lib.repository.createNotebook(title: "Perf", subject: nil, initialPageCount: 20)
        for page in notebook.sortedPages {
            try lib.store.write(content: PageContent(drawing: heavyDrawing, elements: []), pageID: page.id)
        }
        let items = notebook.sortedPages.enumerated().map {
            ExportPageItem(snapshot: $1.renderSnapshot(store: lib.store), notebookTitle: "Perf", pageNumber: $0 + 1)
        }
        let store = lib.store
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let done = expectation(description: "export")
            Task {
                _ = try? await PDFExportService.export(items, options: PDFExportOptions(), store: store,
                                                       to: PDFExportService.temporaryURL(named: "perf"))
                done.fulfill()
            }
            wait(for: [done], timeout: 120)
        }
    }

    func testShapeRecognitionIsFast() {
        let points = (0...400).map { i -> CGPoint in
            let t = CGFloat(i) / 400 * 2 * .pi
            return CGPoint(x: 300 + 100 * cos(t), y: 300 + 100 * sin(t))
        }
        measure {
            for _ in 0..<200 { _ = ShapeRecognizer.recognize(points) }
        }
    }
}
