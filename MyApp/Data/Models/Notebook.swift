import Foundation
import SwiftData

@Model
final class Notebook {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now
    var lastOpenedAt: Date?
    var isFavorite: Bool = false
    var coverColorHex: String = "#3B5BDB"
    /// Page index the user was on when the notebook was closed.
    var lastPageIndex: Int = 0
    /// Encoded `PageStyle` applied to new pages.
    var defaultStyleData: Data?

    var subject: Subject?

    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page]? = []

    @Relationship(deleteRule: .cascade, inverse: \AudioRecording.notebook)
    var recordings: [AudioRecording]? = []

    init(title: String, subject: Subject?, coverColorHex: String = "#3B5BDB", defaultStyle: PageStyle = .default) {
        self.id = UUID()
        self.title = title
        self.subject = subject
        self.coverColorHex = coverColorHex
        self.defaultStyleData = defaultStyle.encoded()
        self.createdAt = .now
        self.modifiedAt = .now
    }

    var defaultStyle: PageStyle {
        get { PageStyle.decode(defaultStyleData) ?? .default }
        set { defaultStyleData = newValue.encoded() }
    }

    /// Pages in display order.
    var sortedPages: [Page] {
        (pages ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var pageCount: Int { pages?.count ?? 0 }

    var sortedRecordings: [AudioRecording] {
        (recordings ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    func touch() { modifiedAt = .now }
}
