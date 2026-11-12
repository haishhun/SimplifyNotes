import SwiftUI
import UniformTypeIdentifiers

/// Grid of notebook covers with context actions.
struct NotebookGridView: View {
    let notebooks: [Notebook]
    let subjects: [Subject]
    let open: (Notebook) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var renaming: Notebook?
    @State private var editing: Notebook?
    @State private var deleting: Notebook?
    @State private var exportItems: [ExportPageItem]?
    @State private var exportTitle = ""
    @State private var importTarget: Notebook?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 28)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 32) {
                ForEach(notebooks) { notebook in
                    NotebookCard(notebook: notebook)
                        .onTapGesture { open(notebook) }
                        .contextMenu { menu(for: notebook) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("notebook-\(notebook.title)")
                }
            }
            .padding(28)
        }
        .background(Theme.Colors.groupedBackground)
        .sheet(item: $editing) { notebook in
            NotebookEditorSheet(mode: .edit(notebook)) { _ in }
        }
        .sheet(isPresented: Binding(get: { exportItems != nil }, set: { if !$0 { exportItems = nil } })) {
            ExportComposerView(items: exportItems ?? [], title: exportTitle, store: env.store)
                .presentationSizing(.page)
        }
        .fileImporter(isPresented: Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } }),
                      allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result, let target = importTarget else { return }
            Task {
                do {
                    let info = try await PDFImportService.importPDF(at: url, store: env.store)
                    try env.repository.insertPDFPages(info, into: target)
                } catch {
                    env.presentedError = error.localizedDescription
                }
            }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Notebook", role: .destructive) {
                if let deleting { env.perform { try env.repository.deleteNotebook(deleting) } }
                deleting = nil
            }
        } message: {
            Text("All \(deleting?.pageCount ?? 0) pages, handwriting and recordings will be permanently deleted.")
        }
    }

    @ViewBuilder
    private func menu(for notebook: Notebook) -> some View {
        Button("Open", systemImage: "book") { open(notebook) }
        Button(notebook.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: notebook.isFavorite ? "star.slash" : "star") {
            env.perform { try env.repository.setFavorite(notebook, !notebook.isFavorite) }
        }
        Button("Rename & Appearance…", systemImage: "pencil") { editing = notebook }
        Menu("Move to Subject", systemImage: "folder") {
            Button("Unfiled") { env.perform { try env.repository.moveNotebook(notebook, to: nil) } }
            ForEach(subjects) { subject in
                Button(subject.name) { env.perform { try env.repository.moveNotebook(notebook, to: subject) } }
            }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            env.perform { _ = try env.repository.duplicateNotebook(notebook) }
        }
        Button("Append PDF Pages…", systemImage: "doc.badge.plus") { importTarget = notebook }
        Button("Export PDF…", systemImage: "square.and.arrow.up") {
            env.store.flush()
            exportTitle = notebook.title
            exportItems = notebook.sortedPages.enumerated().map { index, page in
                ExportPageItem(snapshot: page.renderSnapshot(store: env.store), notebookTitle: notebook.title, pageNumber: index + 1)
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = notebook }
    }
}

struct NotebookCard: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                if let first = notebook.sortedPages.first {
                    PageThumbnailView(page: first, width: 170)
                        .frame(width: 170, height: 220, alignment: .top)
                        .clipped()
                } else {
                    Rectangle().fill(Color.white)
                }
                // Coloured spine
                Rectangle()
                    .fill(Color(hex: notebook.coverColorHex))
                    .frame(width: 12)
            }
            .frame(width: 170, height: 220)
            .clipShape(.rect(cornerRadius: Theme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Theme.Colors.hairline))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .overlay(alignment: .topTrailing) {
                if notebook.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).shadow(radius: 1).padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notebook.title).font(.headline).lineLimit(2)
                Text("\(notebook.pageCount) page\(notebook.pageCount == 1 ? "" : "s") · \(notebook.modifiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let subject = notebook.subject {
                    Text(subject.name).font(.caption2).foregroundStyle(Color(hex: subject.colorHex))
                }
            }
            .frame(width: 170, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notebook.title), \(notebook.pageCount) page\(notebook.pageCount == 1 ? "" : "s")")
    }
}
