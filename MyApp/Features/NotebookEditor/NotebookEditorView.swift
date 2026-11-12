import SwiftUI

/// Owns the editor's view model. The model is created once, when the editor appears;
/// creating it in `init` would rebuild it every time SwiftUI re-creates this view.
struct NotebookEditorView: View {
    let notebook: Notebook
    let env: AppEnvironment
    let initialPageID: UUID?
    @State private var viewModel: NotebookEditorViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NotebookEditorContent(viewModel: viewModel)
            } else {
                Theme.Colors.canvasBackdrop.ignoresSafeArea()
            }
        }
        .onAppear {
            guard viewModel == nil else { return }
            let model = NotebookEditorViewModel(notebook: notebook, env: env, initialPageID: initialPageID)
            model.start()
            viewModel = model
        }
    }
}

/// The notebook editor: top bar, page canvas, floating tool palette, optional page strip.
struct NotebookEditorContent: View {
    @Bindable var viewModel: NotebookEditorViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(ToolSettings.self) private var tools
    @Environment(\.dismiss) private var dismiss
    @State private var isRenamingPage = false
    @State private var pageTitle = ""
    @State private var confirmDeletePage = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if viewModel.showPageSidebar {
                    PageSidebar(viewModel: viewModel)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                ZStack {
                    Theme.Colors.canvasBackdrop.ignoresSafeArea()
                    PageCanvasRepresentable(viewModel: viewModel)
                        .ignoresSafeArea(edges: .bottom)
                    DockedToolbar {
                        EditorToolbar(viewModel: viewModel)
                    }
                    VStack {
                        if viewModel.hasInkSelection || viewModel.selectedElement != nil {
                            SelectionActionBar(viewModel: viewModel)
                                .padding(.top, tools.toolbarPosition == .top ? 72 : 12)
                        }
                        Spacer()
                        pageNavigator
                            .padding(.bottom, tools.toolbarPosition == .bottom ? 8 : 16)
                    }
                    .animation(Theme.Motion.standard, value: viewModel.hasInkSelection || viewModel.selectedElement != nil)
                }
                .coordinateSpace(.named("editor"))
            }
            .animation(Theme.Motion.gentle, value: viewModel.showPageSidebar)
            .toolbar { topBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $viewModel.activeSheet) { sheet in
                sheetContent(sheet)
            }
            .alert("Rename Page", isPresented: $isRenamingPage) {
                TextField("Page title", text: $pageTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save") { viewModel.renameCurrentPage(pageTitle) }
            }
            .confirmationDialog("Delete this page?", isPresented: $confirmDeletePage, titleVisibility: .visible) {
                Button("Delete Page", role: .destructive) { viewModel.deleteCurrentPage() }
            } message: {
                Text("Its handwriting, images and text will be permanently removed.")
            }
            .onChange(of: env.settings.inputPolicy) { viewModel.applyTool() }
            .onChange(of: env.settings.autoShapeCorrection) { viewModel.applyTool() }
        }
    }

    // MARK: Top bar

    @ToolbarContentBuilder
    private var topBar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                viewModel.close()
                dismiss()
            } label: {
                Label("Library", systemImage: "chevron.backward")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier("closeEditor")
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                viewModel.showPageSidebar.toggle()
            } label: {
                Label("Pages Sidebar", systemImage: "sidebar.left")
            }
        }
        ToolbarItem(placement: .principal) {
            PopoverMenuButton {
                [PopoverMenuItem("Rename Page…", systemImage: "pencil", presentsScreen: true) {
                    pageTitle = viewModel.currentPage?.title ?? ""
                    isRenamingPage = true
                 },
                 PopoverMenuItem(viewModel.currentPage?.isBookmarked == true ? "Remove Bookmark" : "Bookmark Page",
                                 systemImage: "bookmark") { viewModel.toggleBookmark() }]
            } label: {
                VStack(spacing: 0) {
                    Text(viewModel.notebook.title).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        if viewModel.currentPage?.isBookmarked == true {
                            Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                        }
                        Text(pageSubtitle)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("editorTitle")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { viewModel.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!viewModel.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button { viewModel.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!viewModel.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button { viewModel.activeSheet = .search } label: { Label("Search", systemImage: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
            Button { viewModel.activeSheet = .pageOverview } label: { Label("Pages", systemImage: "square.grid.2x2") }
                .accessibilityIdentifier("pageOverviewButton")
            PopoverMenuButton {
                [PopoverMenuItem("New Page After", systemImage: "doc.badge.plus") { viewModel.addPage(after: true) },
                 PopoverMenuItem("New Page Before", systemImage: "doc.badge.plus") { viewModel.addPage(after: false) },
                 PopoverMenuItem("Duplicate Page", systemImage: "plus.square.on.square") { viewModel.duplicateCurrentPage() }]
            } label: {
                Label("Add Page", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("addPageMenu")
            PopoverMenuButton {
                [PopoverMenuItem("Export Notebook…", systemImage: "book", presentsScreen: true) {
                    viewModel.activeSheet = .export(viewModel.exportItems(for: viewModel.pages))
                 },
                 PopoverMenuItem("Export This Page…", systemImage: "doc", presentsScreen: true) {
                    viewModel.activeSheet = .export(viewModel.exportItems(for: viewModel.currentPage.map { [$0] } ?? []))
                 },
                 PopoverMenuItem("Choose Pages…", systemImage: "checklist", presentsScreen: true) { viewModel.activeSheet = .export([]) }]
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("exportMenu")
            PopoverMenuButton {
                [PopoverMenuItem("Page Template…", systemImage: "doc.richtext", presentsScreen: true) { viewModel.activeSheet = .pageStyle },
                 PopoverMenuItem(env.audio.isRecording ? "Audio Notes (Recording)" : "Audio Notes", systemImage: "waveform", presentsScreen: true) {
                    viewModel.activeSheet = .audio
                 },
                 PopoverMenuItem("Ruler", systemImage: "ruler", isOn: viewModel.isRulerActive) { viewModel.isRulerActive.toggle() },
                 PopoverMenuItem("Fit Width", systemImage: "arrow.left.and.right") { viewModel.canvas?.zoomToFitWidth() },
                 PopoverMenuItem("Fit Page", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { viewModel.canvas?.zoomToFitPage() },
                 PopoverMenuItem("Delete Page", systemImage: "trash", role: .destructive, presentsScreen: true) { confirmDeletePage = true }]
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("moreMenu")
        }
    }

    private var pageSubtitle: String {
        guard let page = viewModel.currentPage else { return "" }
        let title = page.title.isEmpty ? "Page \(viewModel.currentIndex + 1)" : page.title
        return "\(title) · \(viewModel.pageLabel)"
    }

    private var pageNavigator: some View {
        HStack(spacing: 4) {
            Button { viewModel.previousPage() } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 32)
            }
            .disabled(viewModel.currentIndex == 0)
            .accessibilityLabel("Previous page")
            Button { viewModel.activeSheet = .pageOverview } label: {
                Text(viewModel.pageLabel).font(.footnote.monospacedDigit()).frame(minWidth: 64)
            }
            .accessibilityIdentifier("pageIndicator")
            Button { viewModel.nextPage() } label: {
                Image(systemName: viewModel.currentIndex + 1 < viewModel.pages.count ? "chevron.right" : "plus")
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel(viewModel.currentIndex + 1 < viewModel.pages.count ? "Next page" : "Add page")
            .accessibilityIdentifier("nextPage")
        }
        .buttonStyle(.plain)
        .padding(4)
        .floatingChrome(radius: 20)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .pageOverview:
            PageOverviewView(notebook: viewModel.notebook, currentPageID: viewModel.currentPageID,
                             onOpen: { viewModel.reloadPages(); viewModel.go(toPageID: $0.id) },
                             onChange: { viewModel.reloadPages() },
                             onExport: { pages in
                                 let items = viewModel.exportItems(for: pages)
                                 viewModel.activeSheet = nil
                                 Task { @MainActor in viewModel.activeSheet = .export(items) }
                             })
            .presentationSizing(.page)
            .onAppear { viewModel.autosave.flush() }
            .onDisappear { viewModel.reloadPages() }
        case .pageStyle:
            if let page = viewModel.currentPage {
                PageStyleEditor(initialStyle: page.style, applyLabel: "Apply to This Page",
                                secondaryLabel: "Apply to All Pages",
                                onApply: { viewModel.applyStyle($0, scope: .currentPage) },
                                onSecondary: { viewModel.applyStyle($0, scope: .allPages) })
            }
        case .export(let items):
            ExportComposerView(items: items, title: viewModel.notebook.title, store: env.store,
                               sourceNotebookID: viewModel.notebook.id)
                .presentationSizing(.page)
        case .textEditor(let element, let isNew):
            TextElementEditor(element: element, isNew: isNew) { viewModel.saveTextElement($0, isNew: isNew) }
        case .crop(let element):
            if let name = element.assetName, let image = UIImage(contentsOfFile: env.store.assetURL(named: name).path) {
                ImageCropView(image: image) { viewModel.applyCrop(to: element, croppedImage: $0) }
            }
        case .recognition(let text):
            RecognitionResultSheet(text: text) { viewModel.insertRecognizedText($0, replaceInk: $1) }
        case .linkPicker:
            LinkPickerSheet(pages: viewModel.pages, currentPageID: viewModel.currentPageID) { viewModel.insertLink(to: $0) }
        case .audio:
            AudioNotesView(viewModel: viewModel)
        case .search:
            EditorSearchView(viewModel: viewModel)
        }
    }
}
