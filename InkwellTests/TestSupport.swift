import Foundation
import PencilKit
import SwiftData
import UIKit
@testable import MyApp

/// Isolated environment: in-memory database + temporary file store.
@MainActor
struct TestLibrary {
    let container: ModelContainer
    let store: FilePageContentStore
    let repository: LibraryRepository
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "InkwellTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        container = try PersistenceController.makeContainer(inMemory: true)
        store = FilePageContentStore(rootURL: root)
        repository = LibraryRepository(context: container.mainContext, store: store)
    }

    func pageDirectoryExists(_ id: UUID) -> Bool {
        store.flush()
        return FileManager.default.fileExists(atPath: root.appending(path: "Pages/\(id.uuidString)").path)
    }

    /// Writes ink + a labelled text box so tests can tell pages apart (text is extractable from PDFs).
    func writeContent(_ page: Page, label: String, strokes: Int = 1) throws {
        var elements = [PageElement.textBox(at: CGPoint(x: 72, y: 72), text: label, width: 300)]
        elements[0].frame.size.height = 40
        try store.write(content: PageContent(drawing: TestInk.drawing(strokes: strokes), elements: elements), pageID: page.id)
        repository.contentDidChange(page, elementsText: label)
    }

    func label(of page: Page) -> String? {
        store.loadContentSync(pageID: page.id).elements.first?.text
    }
}

enum TestInk {
    /// A simple horizontal stroke at the given vertical position.
    static func stroke(y: CGFloat = 200, from x0: CGFloat = 100, to x1: CGFloat = 400, color: UIColor = .black) -> PKStroke {
        stroke(points: stride(from: x0, through: x1, by: 4).map { CGPoint(x: $0, y: y) }, color: color)
    }

    static func stroke(points: [CGPoint], color: UIColor = .black, width: CGFloat = 4) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) * 0.01, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: controlPoints, creationDate: .now))
    }

    static func drawing(strokes count: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<count).map { stroke(y: 120 + CGFloat($0 % 60) * 10) })
    }
}

enum TestPDF {
    /// Generates a PDF whose pages contain the given strings as real text.
    static func make(pages texts: [String], size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            for text in texts {
                context.beginPage()
                NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 28)])
                    .draw(at: CGPoint(x: 72, y: 72))
            }
        }
    }

    static func write(pages texts: [String], size: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "source-\(UUID().uuidString).pdf")
        try make(pages: texts, size: size).write(to: url)
        return url
    }
}
