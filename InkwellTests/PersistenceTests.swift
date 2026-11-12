import Testing
import Foundation
import PencilKit
import SwiftData
@testable import MyApp

@MainActor
@Suite("Persistence, recovery & autosave")
struct PersistenceTests {
    @Test func drawingAndElementsRoundTrip() async throws {
        let lib = try TestLibrary()
        let id = UUID()
        let drawing = TestInk.drawing(strokes: 25)
        let elements = [PageElement.textBox(at: .init(x: 10, y: 20), text: "∫ f(x) dx"),
                        PageElement.link(to: UUID(), label: "Lemma", at: .init(x: 50, y: 60))]
        lib.store.save(drawing: drawing, pageID: id)
        lib.store.save(elements: elements, pageID: id)
        let loaded = await lib.store.loadContent(pageID: id)
        #expect(loaded.drawing.strokes.count == 25)
        #expect(loaded.elements == elements)
        #expect(!loaded.recoveredFromBackup)
    }

    @Test func missingContentLoadsEmpty() async throws {
        let lib = try TestLibrary()
        let loaded = await lib.store.loadContent(pageID: UUID())
        #expect(loaded.drawing.strokes.isEmpty)
        #expect(loaded.elements.isEmpty)
        #expect(!loaded.recoveredFromBackup)
    }

    @Test func writesAreAppliedInOrder() throws {
        let lib = try TestLibrary()
        let id = UUID()
        for count in 1...20 { lib.store.save(drawing: TestInk.drawing(strokes: count), pageID: id) }
        #expect(lib.store.loadContentSync(pageID: id).drawing.strokes.count == 20)
    }

    @Test func corruptedPrimaryFileFallsBackToPreviousVersion() throws {
        let lib = try TestLibrary()
        let id = UUID()
        lib.store.save(drawing: TestInk.drawing(strokes: 3), pageID: id)
        lib.store.save(drawing: TestInk.drawing(strokes: 4), pageID: id)   // version 3 becomes .bak
        lib.store.flush()
        // Simulate a torn write / disk corruption of the primary file.
        try Data("garbage".utf8).write(to: lib.store.drawingURL(id))
        let loaded = lib.store.loadContentSync(pageID: id)
        #expect(loaded.recoveredFromBackup)
        #expect(loaded.drawing.strokes.count == 3)
    }

    @Test func missingPrimaryWithBackupRecovers() throws {
        let lib = try TestLibrary()
        let id = UUID()
        lib.store.save(elements: [PageElement.textBox(at: .zero, text: "old")], pageID: id)
        lib.store.save(elements: [PageElement.textBox(at: .zero, text: "new")], pageID: id)
        lib.store.flush()
        try FileManager.default.removeItem(at: lib.store.elementsURL(id))
        let loaded = lib.store.loadContentSync(pageID: id)
        #expect(loaded.elements.first?.text == "old")
        #expect(loaded.recoveredFromBackup)
    }

    @Test func contentSurvivesStoreRelaunch() throws {
        // Simulates an app relaunch: a new store instance over the same directory.
        let lib = try TestLibrary()
        let id = UUID()
        lib.store.save(drawing: TestInk.drawing(strokes: 7), pageID: id)
        lib.store.flush()
        let relaunched = FilePageContentStore(rootURL: lib.root)
        #expect(relaunched.loadContentSync(pageID: id).drawing.strokes.count == 7)
    }

    @Test func metadataSurvivesContainerRelaunch() throws {
        let storeURL = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString).store")
        let fileRoot = FileManager.default.temporaryDirectory.appending(path: "relaunch-files-\(UUID().uuidString)")
        do {
            let container = try PersistenceController.makeContainer(storeURL: storeURL)
            let repository = LibraryRepository(context: container.mainContext, store: FilePageContentStore(rootURL: fileRoot))
            let subject = try repository.createSubject(name: "History")
            let notebook = try repository.createNotebook(title: "Rome", subject: subject, initialPageCount: 3)
            try repository.renamePage(notebook.sortedPages[2], to: "Caesar")
        }
        let reopened = try PersistenceController.makeContainer(storeURL: storeURL)
        let notebooks = try reopened.mainContext.fetch(FetchDescriptor<Notebook>())
        let notebook = try #require(notebooks.first)
        #expect(notebook.title == "Rome")
        #expect(notebook.subject?.name == "History")
        #expect(notebook.sortedPages.map(\.title) == ["", "", "Caesar"])
    }

    @Test func pageStyleDecodingIsTolerant() throws {
        // Older/partial JSON must still decode with defaults.
        let style = try JSONDecoder().decode(PageStyle.self, from: Data(#"{"template":"grid"}"#.utf8))
        #expect(style.template == .grid)
        #expect(style.spacing == PaperTemplate.grid.defaultSpacing)
        #expect(style.paperSize == .letter)
        #expect(PageStyle.default.stableHash == PageStyle().stableHash)
        #expect(PageStyle(template: .dotted).stableHash != PageStyle(template: .grid).stableHash)
    }

    // MARK: Autosave

    @Test func autosaveDebouncesBurstsIntoOneSave() async throws {
        var saves = 0
        let scheduler = AutosaveScheduler(idleDelay: .milliseconds(80), maxDelay: 10) { saves += 1 }
        for _ in 0..<10 { scheduler.markDirty() }
        #expect(saves == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(saves == 1)
        #expect(!scheduler.isPending)
    }

    @Test func autosaveFlushSavesImmediatelyOnce() {
        var saves = 0
        let scheduler = AutosaveScheduler(idleDelay: .seconds(60), maxDelay: 60) { saves += 1 }
        scheduler.flush()
        #expect(saves == 0, "Nothing pending → no save")
        scheduler.markDirty()
        scheduler.flush()
        scheduler.flush()
        #expect(saves == 1)
    }

    @Test func autosaveNeverExceedsMaxDelayDuringContinuousWriting() async throws {
        var saves = 0
        let scheduler = AutosaveScheduler(idleDelay: .seconds(60), maxDelay: 0.2) { saves += 1 }
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 0.5 {
            scheduler.markDirty()          // a stroke every 20 ms, never idle
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(saves >= 2, "Saves are forced while the user keeps writing")
    }

    @Test func contentDidChangeBumpsVersionAndPersists() throws {
        let lib = try TestLibrary()
        let notebook = try lib.repository.createNotebook(title: "N", subject: nil)
        let page = notebook.sortedPages[0]
        let before = page.contentVersion
        lib.repository.contentDidChange(page, elementsText: "hello")
        #expect(page.contentVersion == before + 1)
        #expect(page.elementsText == "hello")
        #expect(!lib.container.mainContext.hasChanges, "Changes are saved immediately")
    }
}
