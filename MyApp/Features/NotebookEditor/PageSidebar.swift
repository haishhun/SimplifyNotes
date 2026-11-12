import SwiftUI

/// Optional thumbnail strip for quick page navigation inside the editor.
struct PageSidebar: View {
    let viewModel: NotebookEditorViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            viewModel.go(to: index)
                        } label: {
                            VStack(spacing: 4) {
                                PageThumbnailView(page: page, width: 96)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(page.id == viewModel.currentPageID ? Color.accentColor : .clear, lineWidth: 2.5)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if page.isBookmarked {
                                            Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.orange).padding(4)
                                        }
                                    }
                                Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(page.id)
                        .accessibilityLabel("Page \(index + 1)")
                    }
                    Button {
                        viewModel.addPage(after: true)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 96, height: 60)
                            .background(Theme.Colors.surface, in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add page")
                }
                .padding(.vertical, 16)
            }
            .onChange(of: viewModel.currentPageID) { _, id in
                withAnimation(Theme.Motion.standard) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(width: 128)
        .background(.regularMaterial)
    }
}
