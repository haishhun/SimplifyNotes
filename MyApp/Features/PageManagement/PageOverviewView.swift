import SwiftUI
import SwiftData

/// Grid of all pages in a notebook: open, reorder (drag & drop), multi-select,
/// duplicate, copy/paste, move to another notebook, bookmark, restyle, export, delete.
struct PageOverviewView: View {
    let notebook: Notebook
    var currentPageID: UUID?
    /// Called when the user taps a page to open it.
    var onOpen: (Page) -> Void
    /// Called after any structural change so the editor can refresh.
    var onChange: () -> Void = {}
    var onExport: ([Page]) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [Page] = []
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var showBookmarksOnly = false
    @State private var renaming: Page?
    @State private var renameText = ""
    @State private var isMoving = false
    @State private var isStyling = false
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    private var visiblePages: [Page] {
        showBookmarksOnly ? pages.filter(\.isBookmarked) : pages
    }

    private var selectedPages: [Page] { pages.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(visiblePages) { page in
                        cell(page)
                    }
                    .reorderable()
                }
                .reorderContainer(for: Page.self) { difference in
                    applyReorder(difference)
                }
                .padding(24)
            }
            .background(Theme.Colors.groupedBackground)
            .navigationTitle("\(notebook.title) — \(pages.count) Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .onAppear(perform: reload)
            .alert("Rename Page", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Page title", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { env.perform { try env.repository.renamePage(renaming, to: renameText) } }
                    renaming = nil
                    changed()
                }
            }
            .confirmationDialog("Delete \(selection.count) page\(selection.count == 1 ? "" : "s")?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete(selectedPages) }
            } message: {
                Text("Handwriting, images and text on these pages will be permanently removed.")
            }
            .sheet(isPresented: $isMoving) {
                MovePagesSheet(excluding: notebook) { destination in
                    env.perform { try env.repository.movePages(selectedPages, to: destination) }
                    selection.removeAll()
                    changed()
                }
            }
            .sheet(isPresented: $isStyling) {
                PageStyleEditor(initialStyle: selectedPages.first?.style ?? notebook.defaultStyle,
                                applyLabel: "Apply to \(selection.count) Page\(selection.count == 1 ? "" : "s")") { style in
                    env.perform { try env.repository.applyStyle(style, to: selectedPages) }
                    changed()
                }
            }
        }
    }

    // MARK: Cells

    private func cell(_ page: Page) -> some View {
        let index = pages.firstIndex { $0.id == page.id } ?? 0
        let isSelected = selection.contains(page.id)
        return VStack(spacing: 8) {
            PageThumbnailView(page: page, width: 150)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.accentColor : (page.id == currentPageID ? Color.accentColor.opacity(0.4) : .clear),
                                      lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .background(Circle().fill(.background))
                            .padding(6)
                    } else if page.isBookmarked {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange).padding(6)
                    }
                }
            HStack(spacing: 4) {
                if page.isPDFBacked { Image(systemName: "doc.richtext").font(.caption2).foregroundStyle(.secondary) }
                Text(page.displayTitle(index: index)).font(.caption).lineLimit(1)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            if isSelecting {
                if isSelected { selection.remove(page.id) } else { selection.insert(page.id) }
            } else {
                onOpen(page)
                dismiss()
            }
        }
        .contextMenu { contextMenu(for: page, index: index) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(page.displayTitle(index: index))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("pageCell-\(index)")
    }

    @ViewBuilder
    private func contextMenu(for page: Page, index: Int) -> some View {
        Button("Open", systemImage: "arrow.up.forward.square") { onOpen(page); dismiss() }
        Button("Rename", systemImage: "pencil") { renameText = page.title; renaming = page }
        Button(page.isBookmarked ? "Remove Bookmark" : "Bookmark", systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark") {
            env.perform { try env.repository.setBookmarked([page], !page.isBookmarked) }
            changed()
        }
        Divider()
        Button("Insert Page Before", systemImage: "arrow.left.to.line") { insertPage(at: index) }
        Button("Insert Page After", systemImage: "arrow.right.to.line") { insertPage(at: index + 1) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            env.perform { _ = try env.repository.duplicatePages([page]) }
            changed()
        }
        Button("Copy", systemImage: "doc.on.doc") { env.pageClipboard = env.repository.snapshot(of: [page]) }
        if !env.pageClipboard.isEmpty {
            Button("Paste After", systemImage: "doc.on.clipboard") { paste(at: index + 1) }
        }
        Button("Export Page…", systemImage: "square.and.arrow.up") { onExport([page]) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            selection = [page.id]
            confirmDelete = true
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showBookmarksOnly) {
                Label("Bookmarks", systemImage: showBookmarksOnly ? "bookmark.fill" : "bookmark")
            }
            .toggleStyle(.button)
            Menu {
                Button("New Page at End", systemImage: "doc.badge.plus") { insertPage(at: pages.count) }
                if !env.pageClipboard.isEmpty {
                    Button("Paste \(env.pageClipboard.count) Page(s) at End", systemImage: "doc.on.clipboard") { paste(at: pages.count) }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button(isSelecting ? "Cancel" : "Select") {
                withAnimation(Theme.Motion.standard) {
                    isSelecting.toggle()
                    selection.removeAll()
                }
            }
            .accessibilityIdentifier("selectPages")
        }
    }

    private var selectionBar: some View {
        let empty = selection.isEmpty
        return HStack(spacing: Theme.Spacing.l) {
            Button(selection.count == visiblePages.count ? "Deselect All" : "Select All") {
                if selection.count == visiblePages.count { selection.removeAll() } else { selection = Set(visiblePages.map(\.id)) }
            }
            Text("\(selection.count) selected").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Group {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    env.perform { _ = try env.repository.duplicatePages(selectedPages) }
                    selection.removeAll()
                    changed()
                }
                .accessibilityIdentifier("duplicateSelectedPages")
                Button("Copy", systemImage: "doc.on.doc") {
                    env.pageClipboard = env.repository.snapshot(of: selectedPages)
                }
                Button("Bookmark", systemImage: "bookmark") {
                    let allBookmarked = selectedPages.allSatisfy(\.isBookmarked)
                    env.perform { try env.repository.setBookmarked(selectedPages, !allBookmarked) }
                    changed()
                }
                Button("Template", systemImage: "doc.richtext") { isStyling = true }
                    .accessibilityIdentifier("styleSelectedPages")
                Button("Move", systemImage: "folder") { isMoving = true }
                Button("Export", systemImage: "square.and.arrow.up") { onExport(selectedPages) }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("deleteSelectedPages")
            }
            .disabled(empty)
            .labelStyle(.iconOnly)
            .font(.title3)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
        .background(.bar)
    }

    // MARK: Actions

    private func reload() {
        pages = notebook.sortedPages
        selection = selection.intersection(pages.map(\.id))
    }

    private func changed() {
        reload()
        onChange()
    }

    private func insertPage(at index: Int) {
        env.perform { _ = try env.repository.addPage(to: notebook, at: index) }
        changed()
    }

    private func paste(at index: Int) {
        env.perform { _ = try env.repository.paste(env.pageClipboard, into: notebook, at: index) }
        changed()
    }

    private func delete(_ targets: [Page]) {
        let ids = targets.map(\.id)
        env.perform { try env.repository.deletePages(targets) }
        env.thumbnails.removeThumbnails(for: ids)
        selection.removeAll()
        changed()
    }

    private func applyReorder(_ difference: ReorderDifference<Page.ID, ReorderableSingleCollectionIdentifier>) {
        let moving = pages.filter { difference.sources.contains($0.id) }
        let target: Page?
        switch difference.destination.position {
        case .before(let id): target = pages.first { $0.id == id }
        case .end: target = nil
        }
        env.perform { try env.repository.reorder(moving, in: notebook, before: target) }
        changed()
    }
}

/// Destination picker for moving pages to another notebook.
struct MovePagesSheet: View {
    let excluding: Notebook?
    let onPick: (Notebook) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Notebook.title) private var notebooks: [Notebook]

    var body: some View {
        NavigationStack {
            List {
                let candidates = notebooks.filter { $0.persistentModelID != excluding?.persistentModelID }
                if candidates.isEmpty {
                    ContentUnavailableView("No Other Notebooks", systemImage: "books.vertical",
                                           description: Text("Create another notebook to move pages into."))
                }
                ForEach(candidates) { notebook in
                    Button {
                        onPick(notebook)
                        dismiss()
                    } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: notebook.coverColorHex)).frame(width: 18, height: 24)
                            VStack(alignment: .leading) {
                                Text(notebook.title)
                                Text(notebook.subject?.name ?? "Unfiled").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(notebook.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Move to Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
