import SwiftUI
import PencilKit

/// Width / opacity / eraser-mode options for the selected tool.
struct ToolOptionsView: View {
    let viewModel: NotebookEditorViewModel
    let tool: ToolKind
    @Environment(ToolSettings.self) private var tools

    var body: some View {
        @Bindable var tools = tools
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Label(tool.displayName, systemImage: tool.symbolName)
                .font(.headline)
            if tool == .eraser {
                Picker("Eraser", selection: $tools.eraserMode) {
                    ForEach(EraserMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tools.eraserMode) { viewModel.applyTool() }
                slider(title: "Size", value: Binding(get: { tools.eraserWidth }, set: { tools.eraserWidth = $0 }),
                       range: tools.widthRange(for: .eraser), format: "%.0f pt")
            } else {
                preview
                slider(title: "Thickness",
                       value: Binding(get: { tools.preset(for: tool).width },
                                      set: { value in tools.updatePreset(for: tool) { $0.width = value } }),
                       range: tools.widthRange(for: tool), format: "%.1f pt")
                slider(title: "Opacity",
                       value: Binding(get: { tools.preset(for: tool).opacity * 100 },
                                      set: { value in tools.updatePreset(for: tool) { $0.opacity = value / 100 } }),
                       range: 10...100, format: "%.0f %%")
                if tool == .shapes {
                    Text("Draw a line, arrow, circle, rectangle or triangle and it snaps into a clean shape.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Reset to Default") {
                    tools.presets[tool] = nil
                    viewModel.applyTool()
                }
                .font(.footnote)
            }
        }
        .padding(Theme.Spacing.l)
    }

    private var preview: some View {
        let preset = tools.preset(for: tool)
        return Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 16, y: size.height * 0.65))
            path.addCurve(to: CGPoint(x: size.width - 16, y: size.height * 0.35),
                          control1: CGPoint(x: size.width * 0.35, y: -size.height * 0.2),
                          control2: CGPoint(x: size.width * 0.6, y: size.height * 1.2))
            context.stroke(path, with: .color(Color(hex: preset.colorHex).opacity(preset.opacity)),
                           style: StrokeStyle(lineWidth: min(preset.width, 30), lineCap: .round))
        }
        .frame(height: 56)
        .background(Color.white, in: .rect(cornerRadius: Theme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Theme.Colors.hairline))
    }

    private func slider(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if !editing { viewModel.applyTool() }
            }
            .onChange(of: value.wrappedValue) { viewModel.applyTool() }
        }
    }
}

/// Palette with system colours plus user-saved custom colours.
struct ColorPaletteView: View {
    let viewModel: NotebookEditorViewModel
    @Environment(ToolSettings.self) private var tools
    @State private var customColor: Color = .blue
    @State private var isEditing = false

    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6)

    var body: some View {
        let currentHex = tools.preset(for: tools.currentTool.isInking ? tools.currentTool : .ballpoint).colorHex
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text(viewModel.hasInkSelection ? "Recolor Selection" : "Colors").font(.headline)
                Spacer()
                if !tools.customColors.isEmpty {
                    Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }.font(.subheadline)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(tools.palette, id: \.self) { hex in
                    let isCustom = tools.customColors.contains(hex)
                    Button {
                        if isEditing && isCustom {
                            tools.removeCustomColor(hex)
                        } else {
                            viewModel.selectColor(hex)
                        }
                    } label: {
                        ColorSwatch(hex: hex, isSelected: hex == currentHex, size: 28)
                            .overlay(alignment: .topTrailing) {
                                if isEditing && isCustom {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red).background(Circle().fill(.white))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCustom ? "Custom color \(hex)" : "Color \(hex)")
                }
            }
            Divider()
            HStack {
                ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
                Button("Save") {
                    let hex = customColor.hexString
                    tools.addCustomColor(hex)
                    viewModel.selectColor(hex)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Theme.Spacing.l)
    }
}

/// Contextual actions for the current lasso selection or selected object.
struct SelectionActionBar: View {
    let viewModel: NotebookEditorViewModel
    @Environment(ToolSettings.self) private var tools

    var body: some View {
        HStack(spacing: 2) {
            if viewModel.hasInkSelection {
                action("Copy", "doc.on.doc") { viewModel.copySelection() }
                action("Cut", "scissors") { viewModel.cutSelection() }
                action("Duplicate", "plus.square.on.square") { viewModel.duplicateSelection() }
                colorMenu
                action("Convert to Text", "character.cursor.ibeam") { viewModel.convertSelectionToText() }
                    .overlay { if viewModel.isRecognizing { ProgressView() } }
                action("Delete", "trash", role: .destructive) { viewModel.deleteSelection() }
            } else if let element = viewModel.selectedElement {
                if element.kind == .text || element.kind == .link {
                    action("Edit", "pencil") { viewModel.activeSheet = .textEditor(element, isNew: false) }
                    colorMenu
                }
                if element.kind == .image {
                    action("Crop", "crop") { viewModel.activeSheet = .crop(element) }
                }
                if element.kind == .link, let target = element.targetPageID {
                    action("Go to Page", "arrow.turn.down.right") { viewModel.go(toPageID: target) }
                }
                action("Duplicate", "plus.square.on.square") { viewModel.duplicateSelection() }
                action("Bring to Front", "square.3.layers.3d.top.filled") { viewModel.canvas?.bringSelectedElementToFront() }
                action("Send to Back", "square.3.layers.3d.bottom.filled") { viewModel.canvas?.sendSelectedElementToBack() }
                action("Delete", "trash", role: .destructive) { viewModel.deleteSelection() }
            }
        }
        .padding(4)
        .floatingChrome(radius: Theme.Radius.m)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var colorMenu: some View {
        Menu {
            ForEach(tools.palette, id: \.self) { hex in
                Button {
                    viewModel.selectColor(hex)
                } label: {
                    Label(hex, systemImage: "circle.fill").tint(Color(hex: hex))
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 36)
                .contentShape(.rect)
        }
        .accessibilityLabel("Recolor")
    }

    private func action(_ title: String, _ symbol: String, role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 36)
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}
