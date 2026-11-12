import Foundation
import SwiftData

struct SearchResult: Identifiable {
    enum Kind { case notebook, page }
    let id = UUID()
    let kind: Kind
    let notebook: Notebook
    let page: Page?
    let pageNumber: Int?
    let snippet: String
}

/// Searches notebook titles, page titles, recognised handwriting, text boxes and PDF text.
@MainActor
struct SearchService {
    let context: ModelContext

    func search(_ rawQuery: String, in notebook: Notebook? = nil, limit: Int = 200) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var results: [SearchResult] = []

        if notebook == nil {
            let notebookDescriptor = FetchDescriptor<Notebook>(
                predicate: #Predicate { $0.title.localizedStandardContains(query) },
                sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
            for match in (try? context.fetch(notebookDescriptor)) ?? [] {
                results.append(SearchResult(kind: .notebook, notebook: match, page: nil, pageNumber: nil,
                                            snippet: "\(match.pageCount) pages"))
            }
        }

        var pageDescriptor = FetchDescriptor<Page>(predicate: #Predicate { page in
            page.title.localizedStandardContains(query)
                || page.recognizedText.localizedStandardContains(query)
                || page.elementsText.localizedStandardContains(query)
                || page.pdfText.localizedStandardContains(query)
        })
        pageDescriptor.fetchLimit = limit
        let pages = (try? context.fetch(pageDescriptor)) ?? []
        for page in pages {
            guard let owner = page.notebook else { continue }
            if let notebook, owner.persistentModelID != notebook.persistentModelID { continue }
            let number = owner.sortedPages.firstIndex { $0.id == page.id } ?? page.sortIndex
            results.append(SearchResult(kind: .page, notebook: owner, page: page, pageNumber: number + 1,
                                        snippet: Self.snippet(for: page, query: query)))
        }
        return results.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .notebook }
            if lhs.notebook.title != rhs.notebook.title { return lhs.notebook.title < rhs.notebook.title }
            return (lhs.pageNumber ?? 0) < (rhs.pageNumber ?? 0)
        }
    }

    /// Short excerpt around the first match.
    static func snippet(for page: Page, query: String) -> String {
        let sources = [page.title, page.elementsText, page.recognizedText, page.pdfText]
        for source in sources {
            guard let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = source.index(range.lowerBound, offsetBy: -40, limitedBy: source.startIndex) ?? source.startIndex
            let end = source.index(range.upperBound, offsetBy: 60, limitedBy: source.endIndex) ?? source.endIndex
            let excerpt = source[start..<end].replacingOccurrences(of: "\n", with: " ")
            return (start > source.startIndex ? "…" : "") + excerpt + (end < source.endIndex ? "…" : "")
        }
        return page.title
    }
}
