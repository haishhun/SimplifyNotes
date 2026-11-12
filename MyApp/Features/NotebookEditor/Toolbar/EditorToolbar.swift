import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Floating tool palette. It can be docked to any screen edge by dragging its grip,
/// and its tool set is configurable in Settings. Kept compact so it never sits
/// where the user writes.
struct EditorToolbar: View {
    @Bindable var viewModel: NotebookEditorViewModel
    @Environment(ToolSettings.self) private var tools
    @State private var photoItem: PhotosPickerItem?
    @State private var isPickingPhoto = false
    @State private var isImportingImage = false
    @State private var isScanning = false

    var body: some View {
        let vertical = tools.toolbarPosition.isVertical
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ToolbarGrip(vertical: vertical)
            ForEach(tools.visibleTools) { tool in
                toolButton(tool)
            }
            divider(vertical)
            insertMenu
            divider(vertical)
            colorButton
            widthDots(vertical: vertical)
            divider(vertical)
            ToolbarIconButton(systemName: "arrow.uturn.backward", label: "Undo", tint: viewModel.canUndo ? .primary : .secondary) {
                viewModel.undo()
            }
            .disabled(!viewModel.canUndo)
            ToolbarIconButton(systemName: "arrow.uturn.forward", label: "Redo", tint: viewModel.canRedo ? .primary : .secondary) {
                viewModel.redo()
            }
            .disabled(!viewModel.canRedo)
        }
        .padding(6)
        .floatingChrome()
        .photosPicker(isPresented: $isPickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { viewModel.insertImage(data: data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $isImportingImage, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { viewModel.insertImage(data: data) }
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScannerView { images in
                isScanning = false
                for image in images {
                    if let data = image.jpegData(compressionQuality: 0.9) { viewModel.insertImage(data: data) }
                }
            } onCancel: {
                isScanning = false
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func toolButton(_ tool: ToolKind) -> some View {
        let selected = tools.currentTool == tool
        ToolbarIconButton(systemName: tool.symbolName, label: tool.displayName, isSelected: selected,
                          tint: tool.isInking && tool != .shapes ? Color(hex: tools.preset(for: tool).colorHex) : .primary) {
            viewModel.select(tool)
        }
        .popover(isPresented: Binding(get: { selected && viewModel.isShowingToolOptions },
                                      set: { viewModel.isShowingToolOptions = $0 })) {
            ToolOptionsView(viewModel: viewModel, tool: tool)
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityIdentifier("tool-\(tool.rawValue)")
    }

    private var insertMenu: some View {
        PopoverMenuButton {
            var items = [
                PopoverMenuItem("Photo Library", systemImage: "photo.on.rectangle", presentsScreen: true) { isPickingPhoto = true },
                PopoverMenuItem("Image from Files", systemImage: "folder", presentsScreen: true) { isImportingImage = true }
            ]
            if UIPasteboard.general.hasImages {
                items.append(PopoverMenuItem("Paste Image", systemImage: "doc.on.clipboard") {
                    if let data = UIPasteboard.general.image?.pngData() { viewModel.insertImage(data: data) }
                })
            }
            if DocumentScannerView.isSupported {
                items.append(PopoverMenuItem("Scan Document", systemImage: "doc.viewfinder", presentsScreen: true) { isScanning = true })
            }
            items.append(PopoverMenuItem("Text Box", systemImage: "character.textbox") { viewModel.select(.text) })
            items.append(PopoverMenuItem("Link to Page…", systemImage: "link", presentsScreen: true) { viewModel.activeSheet = .linkPicker })
            if viewModel.canPasteInk {
                items.append(PopoverMenuItem("Paste Handwriting", systemImage: "doc.on.clipboard") { viewModel.pasteInk() })
            }
            return items
        } label: {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Insert")
        .accessibilityIdentifier("insertMenu")
    }

    private var colorButton: some View {
        let hex = tools.preset(for: tools.currentTool.isInking ? tools.currentTool : .ballpoint).colorHex
        return Button {
            viewModel.isShowingColorPicker.toggle()
        } label: {
            ColorSwatch(hex: hex, size: 24)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
        .popover(isPresented: $viewModel.isShowingColorPicker) {
            ColorPaletteView(viewModel: viewModel)
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Three quick width presets for the current inking tool.
    @ViewBuilder
    private func widthDots(vertical: Bool) -> some View {
        let tool = tools.currentTool
        if tool.isInking || tool == .eraser {
            let range = tools.widthRange(for: tool)
            let presets = [range.lowerBound + (range.upperBound - range.lowerBound) * 0.04,
                           range.lowerBound + (range.upperBound - range.lowerBound) * 0.12,
                           range.lowerBound + (range.upperBound - range.lowerBound) * 0.3]
            let current = tool == .eraser ? tools.eraserWidth : tools.preset(for: tool).width
            ForEach(Array(presets.enumerated()), id: \.offset) { index, width in
                Button {
                    if tool == .eraser { tools.eraserWidth = width } else { tools.updatePreset(for: tool) { $0.width = width } }
                    viewModel.applyTool()
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: CGFloat(5 + index * 4), height: CGFloat(5 + index * 4))
                        .frame(width: 30, height: 40)
                        .background {
                            if abs(current - width) < 0.01 {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Width \(index + 1)")
            }
        }
    }

    @ViewBuilder
    private func divider(_ vertical: Bool) -> some View {
        if vertical {
            Divider().frame(width: 28)
        } else {
            Divider().frame(height: 28)
        }
    }
}

/// Drag handle; dropping the toolbar near an edge docks it there.
struct ToolbarGrip: View {
    let vertical: Bool

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(vertical ? .zero : .degrees(90))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: vertical ? 40 : 18, height: vertical ? 18 : 40)
            .contentShape(.rect)
            .accessibilityLabel("Move toolbar")
    }
}

/// Positions the toolbar along the chosen edge and handles drag-to-redock.
struct DockedToolbar<Content: View>: View {
    @Environment(ToolSettings.self) private var tools
    @State private var dragOffset: CGSize = .zero
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let position = tools.toolbarPosition
            content
                .offset(dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .named("editor"))
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            let location = value.location
                            let size = proxy.size
                            let distances: [(ToolbarPosition, CGFloat)] = [
                                (.top, location.y), (.bottom, size.height - location.y),
                                (.leading, location.x), (.trailing, size.width - location.x)
                            ]
                            let nearest = distances.min { $0.1 < $1.1 }?.0 ?? position
                            withAnimation(Theme.Motion.gentle) {
                                tools.toolbarPosition = nearest
                                dragOffset = .zero
                            }
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: position))
                .padding(padding(for: position))
                .animation(Theme.Motion.gentle, value: position)
        }
    }

    private func alignment(for position: ToolbarPosition) -> Alignment {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    private func padding(for position: ToolbarPosition) -> EdgeInsets {
        switch position {
        case .top: EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0)
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0)
        case .leading: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0)
        case .trailing: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12)
        }
    }
}
