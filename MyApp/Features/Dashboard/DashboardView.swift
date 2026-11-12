import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Sidebar sections of the library.
enum LibrarySection: Hashable {
    case all, favorites, recents, unfiled
    case subject(UUID)
}

/// Library home: subjects in the sidebar, notebooks in a grid, global search.
struct DashboardView: View {
    let openNotebook: (Notebook, UUID?) -> Void

    @Environment(AppEnvironment.self) private var env
    @Query(sort: [SortDescriptor(\Subject.sortIndex), SortDescriptor(\Subject.createdAt)]) private var subjects: [Subject]
    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @State private var section: LibrarySection? = .all
    @State private var searchText = ""
    @State private var editingSubject: SubjectEditorSheet.Mode?
    @State private var subjectToDelete: Subject?
    @State private var isCreatingNotebook = false
    @State private var isImportingPDF = false
    @State private var isScanning = false
    @State private var isShowingSettings = false
    @State private var isShowingExport = false
    @State private var importProgress: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(title)
                    .toolbar { detailToolbar }
                    .searchable(text: $searchText, placement: .toolbar, prompt: "Search notes & handwriting")
            }
        }
        .sheet(item: $editingSubject) { mode in
            SubjectEditorSheet(mode: mode)
        }
        .sheet(isPresented: $isCreatingNotebook) {
            NotebookEditorSheet(mode: .create(subject: currentSubject)) { notebook in
                openNotebook(notebook, nil)
            }
        }
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .sheet(isPresented: $isShowingExport) {
            ExportComposerView(items: [], title: "Notes", store: env.store)
                .presentationSizing(.page)
        }
        .fileImporter(isPresented: $isImportingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importPDFs(urls)
            case .failure(let error): env.presentedError = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScannerView { images in
                isScanning = false
                importScans(images)
            } onCancel: {
                isScanning = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Delete “\(subjectToDelete?.name ?? "")”?", isPresented: Binding(get: { subjectToDelete != nil },
                                                                                             set: { if !$0 { subjectToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Subject and Notebooks", role: .destructive) {
                if let subject = subjectToDelete {
                    if case .subject(subject.id) = section { section = .all }
                    env.perform { try env.repository.deleteSubject(subject) }
                }
                subjectToDelete = nil
            }
        } message: {
            Text("All \(subjectToDelete?.notebooks?.count ?? 0) notebooks in this subject and their pages will be deleted.")
        }
        .overlay(alignment: .bottom) {
            if let importProgress {
                Label(importProgress, systemImage: "arrow.down.doc")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .floatingChrome(radius: 20)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.standard, value: importProgress)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                Label("All Notebooks", systemImage: "books.vertical").tag(LibrarySection.all)
                Label("Favorites", systemImage: "star").tag(LibrarySection.favorites)
                Label("Recent", systemImage: "clock").tag(LibrarySection.recents)
                if notebooks.contains(where: { $0.subject == nil }) {
                    Label("Unfiled", systemImage: "tray").tag(LibrarySection.unfiled)
                }
            }
            Section {
                ForEach(subjects) { subject in
                    Label {
                        HStack {
                            Text(subject.name)
                            Spacer()
                            Text("\(subject.notebooks?.count ?? 0)").foregroundStyle(.secondary).font(.caption)
                        }
                    } icon: {
                        Image(systemName: subject.symbolName).foregroundStyle(Color(hex: subject.colorHex))
                    }
                    .tag(LibrarySection.subject(subject.id))
                    .contextMenu {
                        Button("Edit Subject…", systemImage: "pencil") { editingSubject = .edit(subject) }
                        Button("Delete", systemImage: "trash", role: .destructive) { subjectToDelete = subject }
                    }
                    .accessibilityIdentifier("subject-\(subject.name)")
                }
            } header: {
                HStack {
                    Text("Subjects")
                    Spacer()
                    Button {
                        editingSubject = .create
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("New Subject")
                    .accessibilityIdentifier("newSubject")
                }
            }
        }
        .navigationTitle("SimplifyNotes")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                    .accessibilityIdentifier("settingsButton")
            }
        }
    }

    // MARK: Detail

    private var currentSubject: Subject? {
        if case .subject(let id) = section { return subjects.first { $0.id == id } }
        return nil
    }

    private var title: String {
        switch section ?? .all {
        case .all: "All Notebooks"
        case .favorites: "Favorites"
        case .recents: "Recent"
        case .unfiled: "Unfiled"
        case .subject: currentSubject?.name ?? "Subject"
        }
    }

    private var filteredNotebooks: [Notebook] {
        switch section ?? .all {
        case .all: notebooks
        case .favorites: notebooks.filter(\.isFavorite)
        case .recents:
            Array(notebooks.filter { $0.lastOpenedAt != nil }
                .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
                .prefix(20))
        case .unfiled: notebooks.filter { $0.subject == nil }
        case .subject(let id): notebooks.filter { $0.subject?.id == id }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            LibrarySearchResultsView(query: searchText, open: openNotebook)
        } else if filteredNotebooks.isEmpty {
            emptyState
        } else {
            NotebookGridView(notebooks: filteredNotebooks, subjects: subjects, open: { openNotebook($0, nil) })
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch section ?? .all {
        case .favorites:
            ContentUnavailableView("No Favorites", systemImage: "star",
                                   description: Text("Mark notebooks with a star to find them here."))
        case .recents:
            ContentUnavailableView("Nothing Opened Yet", systemImage: "clock",
                                   description: Text("Notebooks you open appear here."))
        default:
            ContentUnavailableView {
                Label("No Notebooks", systemImage: "book.closed")
            } description: {
                Text(subjects.isEmpty ? "Create a subject for each course, then add notebooks — or import a PDF to annotate."
                                      : "Create a notebook or import a PDF to start writing.")
            } actions: {
                Button("New Notebook") { isCreatingNotebook = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("emptyNewNotebook")
                Button("Import PDF") { isImportingPDF = true }
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { isShowingExport = true } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("libraryExport")
            PopoverMenuButton {
                var items = [PopoverMenuItem("Import PDF…", systemImage: "doc.badge.arrow.up", presentsScreen: true) { isImportingPDF = true }]
                if DocumentScannerView.isSupported {
                    items.append(PopoverMenuItem("Scan Document…", systemImage: "doc.viewfinder", presentsScreen: true) { isScanning = true })
                }
                return items
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("importMenu")
            Button { isCreatingNotebook = true } label: { Label("New Notebook", systemImage: "plus") }
                .accessibilityIdentifier("newNotebook")
        }
    }

    // MARK: Import

    private func importPDFs(_ urls: [URL]) {
        let subject = currentSubject
        Task {
            var lastNotebook: Notebook?
            for (index, url) in urls.enumerated() {
                importProgress = urls.count > 1 ? "Importing \(index + 1) of \(urls.count)…" : "Importing “\(url.lastPathComponent)”…"
                do {
                    let info = try await PDFImportService.importPDF(at: url, store: env.store)
                    lastNotebook = try env.repository.createNotebook(fromPDF: info, subject: subject)
                } catch {
                    env.presentedError = error.localizedDescription
                }
            }
            importProgress = nil
            if urls.count == 1, let lastNotebook { openNotebook(lastNotebook, nil) }
        }
    }

    private func importScans(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let subject = currentSubject
        Task {
            importProgress = "Processing \(images.count) scanned page\(images.count == 1 ? "" : "s")…"
            defer { importProgress = nil }
            let data = await Task.detached(priority: .userInitiated) { PDFImportService.makePDF(from: images) }.value
            let title = "Scan " + Date.now.formatted(date: .abbreviated, time: .shortened)
            do {
                let info = try await PDFImportService.importPDF(data: data, title: title, store: env.store)
                let notebook = try env.repository.createNotebook(fromPDF: info, subject: subject)
                openNotebook(notebook, nil)
            } catch {
                env.presentedError = error.localizedDescription
            }
        }
    }
}
