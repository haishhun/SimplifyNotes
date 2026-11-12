import SwiftUI
import SwiftData

/// Chooses a paper template and customises colours, spacing, size, margins and orientation.
/// Changing the template never touches the page's ink.
struct PageStyleEditor: View {
    @State private var style: PageStyle
    let applyLabel: String
    var secondaryLabel: String?
    let onApply: (PageStyle) -> Void
    var onSecondary: ((PageStyle) -> Void)?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TemplatePreset.createdAt) private var presets: [TemplatePreset]
    @State private var savingName = ""
    @State private var isSaving = false

    init(initialStyle: PageStyle, applyLabel: String, secondaryLabel: String? = nil,
         onApply: @escaping (PageStyle) -> Void, onSecondary: ((PageStyle) -> Void)? = nil) {
        self.style = initialStyle
        self.applyLabel = applyLabel
        self.secondaryLabel = secondaryLabel
        self.onApply = onApply
        self.onSecondary = onSecondary
    }

    private let templateColumns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PaperPreview(style: style).frame(height: 220)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Template") {
                    LazyVGrid(columns: templateColumns, spacing: 12) {
                        ForEach(PaperTemplate.allCases) { template in
                            Button {
                                let previous = style.template
                                style.template = template
                                if style.spacing == previous.defaultSpacing { style.spacing = template.defaultSpacing }
                            } label: {
                                VStack(spacing: 6) {
                                    PaperPreview(style: PageStyle(template: template, backgroundColorHex: style.backgroundColorHex,
                                                                  lineColorHex: style.lineColorHex, marginTop: 40, marginLeft: 50),
                                                 aspect: CGSize(width: 612, height: 792))
                                        .frame(height: 96)
                                        .overlay(RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(style.template == template ? Color.accentColor : .clear, lineWidth: 2.5))
                                    Text(template.displayName).font(.caption).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(template.displayName)
                            .accessibilityIdentifier("template-\(template.rawValue)")
                            .accessibilityAddTraits(style.template == template ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                if !presets.isEmpty {
                    Section("My Templates") {
                        ForEach(presets) { preset in
                            Button {
                                style = preset.style
                            } label: {
                                HStack {
                                    PaperPreview(style: preset.style).frame(height: 44)
                                    Text(preset.name)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { env.perform { try env.repository.deleteTemplate(presets[index]) } }
                        }
                    }
                }
                Section("Paper") {
                    Picker("Size", selection: $style.paperSize) {
                        ForEach(PaperSize.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Orientation", selection: $style.orientation) {
                        ForEach(PaperOrientation.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ColorPicker("Paper Color", selection: Binding(get: { Color(hex: style.backgroundColorHex) },
                                                                 set: { style.backgroundColorHex = $0.hexString }),
                                supportsOpacity: false)
                    ColorPicker("Line Color", selection: Binding(get: { Color(hex: style.lineColorHex) },
                                                                set: { style.lineColorHex = $0.hexString }),
                                supportsOpacity: false)
                }
                Section("Spacing & Margins") {
                    LabeledSlider(title: "Line / Grid Spacing", value: $style.spacing, range: 4...60, unit: "pt")
                    LabeledSlider(title: "Top Margin", value: $style.marginTop, range: 0...200, unit: "pt")
                    LabeledSlider(title: "Left Margin", value: $style.marginLeft, range: 0...200, unit: "pt")
                }
                Section {
                    Button("Save as Custom Template…", systemImage: "square.and.arrow.down") { isSaving = true }
                }
            }
            .navigationTitle("Page Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button(applyLabel) { onApply(style); dismiss() }
                        if let secondaryLabel, let onSecondary {
                            Button(secondaryLabel) { onSecondary(style); dismiss() }
                        }
                    } label: {
                        Text("Apply").bold()
                    } primaryAction: {
                        onApply(style)
                        dismiss()
                    }
                    .accessibilityIdentifier("applyTemplate")
                }
            }
            .alert("Save Template", isPresented: $isSaving) {
                TextField("Name", text: $savingName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    env.perform { _ = try env.repository.saveTemplate(name: savingName, style: style) }
                    savingName = ""
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, specifier: "%.1f") \(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
