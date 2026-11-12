import SwiftUI
import SwiftData
import PDFKit

/// Builds a combined PDF from pages of one or more notebooks.
/// Left: source notebook pages (tap to select, range entry). Right: the export
/// order (drag to reorder), options, preview and sharing.
struct ExportComposerView: View {
    @State private var model: ExportComposerViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Notebook.title) private var notebooks: [Notebook]
    @State private var sourceNotebookID: UUID?
    @State private var sourceSelection = Set<UUID>()
    @State private var rangeText = ""
    @State private var rangeError: String?
    @State private var showPreview = false

    init(items: [ExportPageItem], title: String, store: PageContentStoring, sourceNotebookID: UUID? = nil) {
        self.model = ExportComposerViewModel(items: items, title: title, store: store)
        self.sourceNotebookID = sourceNotebookID
    }

    private var sourceNotebook: Notebook? {
        notebooks.first { $0.id == sourceNotebookID } ?? notebooks.first
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                sourcePanel
                    .frame(minWidth: 320, maxWidth: .infinity)
                Divider()
                queuePanel
                    .frame(width: 380)
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { model.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.generate()
                        showPreview = true
                    } label: {
                        Label("Preview & Export", systemImage: "doc.viewfinder")
                    }
                    .disabled(model.queue.isEmpty)
                    .accessibilityIdentifier("previewExport")
                }
            }
            .navigationDestination(isPresented: $showPreview) {
                PDFPreviewScreen(model: model)
            }
            .alert("Export", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    // MARK: Source

    private var sourcePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Notebook", selection: Binding(get: { sourceNotebook?.id }, set: { sourceNotebookID = $0; sourceSelection.removeAll() })) {
                    ForEach(notebooks) { notebook in
                        Text(notebook.title).tag(Optional(notebook.id))
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                if let notebook = sourceNotebook {
                    Button("Add All") { model.add(notebook.sortedPages, from: notebook) }
                    Button("Add Selected (\(sourceSelection.count))") {
                        model.add(notebook.sortedPages.filter { sourceSelection.contains($0.id) }, from: notebook)
                        sourceSelection.removeAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceSelection.isEmpty)
                    .accessibilityIdentifier("addSelectedPages")
                }
            }
            .padding()
            HStack {
                TextField("Page range, e.g. 1-3, 5, 8-", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit(addRange)
                Button("Add Range", action: addRange).disabled(rangeText.isEmpty)
            }
            .padding(.horizontal)
            if let rangeError {
                Text(rangeError).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if let notebook = sourceNotebook {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
                        ForEach(Array(notebook.sortedPages.enumerated()), id: \.element.id) { index, page in
                            let selected = sourceSelection.contains(page.id)
                            VStack(spacing: 4) {
                                PageThumbnailView(page: page, width: 116)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                                            .background(Circle().fill(.background))
                                            .padding(4)
                                    }
                                Text("\(index + 1)").font(.caption)
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                if selected { sourceSelection.remove(page.id) } else { sourceSelection.insert(page.id) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Page \(index + 1)")
                            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                            .accessibilityIdentifier("exportSource-\(index)")
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("No Notebooks", systemImage: "books.vertical")
            }
        }
        .background(Theme.Colors.groupedBackground)
    }

    private func addRange() {
        guard let notebook = sourceNotebook else { return }
        do {
            try model.addRange(rangeText, from: notebook)
            rangeText = ""
            rangeError = nil
        } catch PageRangeParser.ParseError.outOfBounds(let number) {
            rangeError = "Page \(number) doesn't exist — this notebook has \(notebook.pageCount) pages."
        } catch {
            rangeError = "Use numbers and ranges like 1-3, 5, 8-."
        }
    }

    // MARK: Queue & options

    private var queuePanel: some View {
        List {
            Section {
                if model.queue.isEmpty {
                    Text("Add pages from the left. You can combine pages from several notebooks.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.queue) { item in
                    HStack(spacing: 12) {
                        Text("\((model.queue.firstIndex(of: item) ?? 0) + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(item.notebookTitle).lineLimit(1)
                            Text("Page \(item.pageNumber)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { model.remove(atOffsets: $0) }
            } header: {
                HStack {
                    Text("Export Order (\(model.queue.count))")
                    Spacer()
                    if !model.queue.isEmpty {
                        Button("Reverse") { model.reverse() }.font(.caption)
                        Button("Clear", role: .destructive) { model.removeAll() }.font(.caption)
                    }
                }
            }
            Section("Options") {
                TextField("File name", text: $model.options.title)
                Picker("Page Size", selection: $model.options.paperSize) {
                    ForEach(ExportPaperSize.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Orientation", selection: $model.options.orientation) {
                    ForEach(ExportOrientation.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(model.options.paperSize == .original)
                Toggle("Include Page Backgrounds", isOn: $model.options.includeBackgrounds)
                Picker("Ink Quality", selection: $model.options.inkScale) {
                    Text("Standard").tag(CGFloat(2))
                    Text("High").tag(CGFloat(3))
                    Text("Print").tag(CGFloat(4))
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .onChange(of: model.options) { model.invalidatePreview() }
    }
}

/// Shows the generated PDF and offers native sharing (Files, AirDrop, Mail…).
struct PDFPreviewScreen: View {
    let model: ExportComposerViewModel

    var body: some View {
        Group {
            if let url = model.previewURL {
                PDFKitView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            } else if model.isExporting {
                VStack(spacing: 16) {
                    ProgressView(value: model.progress) {
                        Text("Creating PDF…")
                    } currentValueLabel: {
                        Text("\(Int(model.progress * 100)) %").monospacedDigit()
                    }
                    .frame(width: 280)
                    Button("Cancel") { model.cancel() }
                }
            } else {
                ContentUnavailableView {
                    Label("No Preview", systemImage: "doc")
                } actions: {
                    Button("Generate PDF") { model.generate() }
                }
            }
        }
        .navigationTitle(model.options.title)
        .toolbar {
            if let url = model.previewURL {
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("sharePDF")
                }
            }
        }
        .onAppear {
            if model.previewURL == nil && !model.isExporting { model.generate() }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        view.accessibilityIdentifier = "pdfPreview"
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
