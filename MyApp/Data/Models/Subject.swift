import Foundation
import SwiftData

/// Top level of the hierarchy: Subjects → Notebooks → Pages.
/// All attributes have defaults and relationships are optional so the schema
/// stays compatible with a future CloudKit-backed `ModelConfiguration`.
@Model
final class Subject {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#4C6EF5"
    var symbolName: String = "book.closed"
    var createdAt: Date = Date.now
    var sortIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Notebook.subject)
    var notebooks: [Notebook]? = []

    init(name: String, colorHex: String = "#4C6EF5", symbolName: String = "book.closed", sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    var sortedNotebooks: [Notebook] {
        (notebooks ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
