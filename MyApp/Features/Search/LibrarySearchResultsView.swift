import SwiftData
import SwiftUI

/// Global search results: notebooks by title and pages by title, handwriting, text boxes and PDF text.
struct LibrarySearchResultsView: View {
    let query: String
    let open: (Notebook, UUID?) -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let results = SearchService(context: env.container.mainContext).search(query)
        List {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            let notebookResults = results.filter { $0.kind == .notebook }
            if !notebookResults.isEmpty {
                Section("Notebooks") {
                    ForEach(notebookResults) { result in
                        Button { open(result.notebook, nil) } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(result.notebook.title)
                                    Text(result.snippet).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "book.closed").foregroundStyle(Color(hex: result.notebook.coverColorHex))
                            }
                        }
                    }
                }
            }
            let pageResults = results.filter { $0.kind == .page }
            if !pageResults.isEmpty {
                Section("Pages") {
                    ForEach(pageResults) { result in
                        Button { open(result.notebook, result.page?.id) } label: {
                            HStack(spacing: 12) {
                                if let page = result.page { PageThumbnailView(page: page, width: 48) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(result.notebook.title) — Page \(result.pageNumber ?? 0)")
                                    Text(result.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
