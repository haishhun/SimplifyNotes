import XCTest

/// End-to-end flows. The app runs with `-uiTesting`, which uses an in-memory
/// library and temporary file storage so every test starts clean.
final class InkwellUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    // MARK: Helpers

    private func createSubject(_ name: String) {
        app.buttons["newSubject"].tap()
        let field = app.textFields["subjectNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Return submits the form (tapping Save races the keyboard moving the sheet).
        field.typeText(name + "\n")
        XCTAssertTrue(app.descendants(matching: .any)["subject-\(name)"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Creates a notebook; the editor opens automatically.
    private func createNotebook(_ title: String) {
        app.buttons["newNotebook"].firstMatch.tap()
        let field = app.textFields["notebookTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title + "\n")
        XCTAssertTrue(app.otherElements["pageCanvas"].waitForExistence(timeout: 10) ||
                      app.scrollViews["pageCanvas"].waitForExistence(timeout: 2), "Editor should open")
    }

    private var canvas: XCUIElement {
        let scroll = app.scrollViews["pageCanvas"]
        return scroll.exists ? scroll : app.otherElements["pageCanvas"]
    }

    private func waitForIndicator(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let indicator = app.buttons["pageIndicator"]
        let predicate = NSPredicate(format: "label == %@", label)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: indicator)], timeout: 5)
        XCTAssertEqual(result, .completed, "Page indicator should read “\(label)” but was “\(indicator.label)”", file: file, line: line)
    }

    /// Opens a toolbar menu and taps an item, retrying if the toolbar was mid-update.
    private func closeEditor() {
        app.buttons["closeEditor"].tap()
        XCTAssertTrue(app.buttons["newNotebook"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Flows

    @MainActor
    func testCreateSubjectAndNotebookThenWrite() throws {
        createSubject("Linear Algebra")
        createNotebook("Lecture 1")

        // Draw a stroke (simulator input is a finger, which draws unless "Pencil Only" is set).
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)

        let undo = app.navigationBars.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: undo)
        waitForExpectations(timeout: 5)

        undo.tap()
        let disabled = NSPredicate(format: "isEnabled == false")
        expectation(for: disabled, evaluatedWith: undo)
        waitForExpectations(timeout: 5)

        closeEditor()
        XCTAssertTrue(app.descendants(matching: .any)["notebook-Lecture 1"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAddPagesAndManageThemInOverview() throws {
        createNotebook("Pages")
        let indicator = app.buttons["pageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, "1 of 1")

        app.buttons["nextPage"].tap()          // at the last page, "next" adds a page
        waitForIndicator("2 of 2")
        app.buttons["nextPage"].tap()
        waitForIndicator("3 of 3")

        // Overview → duplicate the first page.
        app.buttons["pageOverviewButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pageCell-2"].waitForExistence(timeout: 5))
        app.buttons["selectPages"].tap()
        app.descendants(matching: .any)["pageCell-0"].tap()
        app.buttons["duplicateSelectedPages"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pageCell-3"].waitForExistence(timeout: 5), "Duplicate adds a fourth page")

        // Select two pages → delete → two remain.
        app.descendants(matching: .any)["pageCell-0"].tap()
        app.descendants(matching: .any)["pageCell-1"].tap()
        app.buttons["deleteSelectedPages"].tap()
        // The confirmation button, not the toolbar's own "Delete" button.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != 'deleteSelectedPages'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pageCell-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["pageCell-2"].exists)
        app.buttons["Done"].firstMatch.tap()
        // Pages were [P1, P1-copy, P2, P3]; deleting the first two keeps the editor on P3.
        waitForIndicator("2 of 2")
    }

    @MainActor
    func testCombinedExportPreviewAndShare() throws {
        createNotebook("Physics")
        app.buttons["nextPage"].tap()
        waitForIndicator("2 of 2")
        closeEditor()
        createNotebook("Chemistry")
        closeEditor()

        app.buttons["libraryExport"].tap()
        // Add pages from the default source notebook, then preview.
        let firstSource = app.descendants(matching: .any)["exportSource-0"]
        XCTAssertTrue(firstSource.waitForExistence(timeout: 5))
        firstSource.tap()
        app.buttons["addSelectedPages"].tap()
        app.buttons["Add All"].tap()
        app.buttons["previewExport"].tap()

        XCTAssertTrue(app.buttons["sharePDF"].waitForExistence(timeout: 20), "PDF is generated and can be shared")
        XCTAssertTrue(app.descendants(matching: .any)["pdfPreview"].exists)
    }

    @MainActor
    func testToolSelectionAndPageTemplate() throws {
        createNotebook("Tools")
        for tool in ["fountain", "highlighter", "eraser", "lasso", "ballpoint"] {
            let button = app.buttons["tool-\(tool)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "\(tool) button")
            button.tap()
            XCTAssertTrue(button.isSelected, "\(tool) becomes the active tool")
        }
        // Change the template of a page from the overview.
        app.buttons["pageOverviewButton"].tap()
        app.buttons["selectPages"].tap()
        app.descendants(matching: .any)["pageCell-0"].tap()
        app.buttons["styleSelectedPages"].tap()
        let apply = app.descendants(matching: .any)["applyTemplate"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "Template sheet opens")
        let dotted = app.buttons["template-dotted"]
        XCTAssertTrue(dotted.waitForExistence(timeout: 5))
        dotted.tap()
        XCTAssertTrue(dotted.isSelected, "Dotted becomes the chosen template")
        apply.tap()
        XCTAssertTrue(app.buttons["selectPages"].waitForExistence(timeout: 5), "Back in the overview after applying")
    }
}
