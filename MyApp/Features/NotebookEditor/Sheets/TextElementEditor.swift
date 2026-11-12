import SwiftUI

/// Edits a text box: content, size, font and colour, plus a math-symbol palette.
struct TextElementEditor: View {
    @State private var element: PageElement
    let isNew: Bool
    let onSave: (PageElement) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ToolSettings.self) private var tools
    @FocusState private var focused: Bool

    static let mathSymbols = ["±", "×", "÷", "≠", "≈", "≤", "≥", "∞", "√", "∑", "∏", "∫", "∂", "∇", "Δ",
                              "π", "θ", "λ", "μ", "σ", "α", "β", "γ", "ε", "φ", "ω", "→", "⇒", "⇔", "∈",
                              "∉", "⊂", "∪", "∩", "∀", "∃", "ℝ", "ℕ", "ℤ", "²", "³", "ⁿ", "₁", "₂", "°"]

    init(element: PageElement, isNew: Bool, onSave: @escaping (PageElement) -> Void) {
        self.element = element
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $element.text)
                        .font(Font(ElementStyle.font(for: element)))
                        .foregroundStyle(Color(hex: element.colorHex))
                        .frame(minHeight: 160)
                        .focused($focused)
                        .accessibilityIdentifier("textElementEditor")
                }
                Section("Math & Symbols") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.mathSymbols, id: \.self) { symbol in
                                Button(symbol) { element.text += symbol }
                                    .font(.title3)
                                    .frame(minWidth: 34, minHeight: 34)
                                    .background(Theme.Colors.groupedBackground, in: .rect(cornerRadius: 8))
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Style") {
                    Stepper("Size: \(Int(element.fontSize)) pt", value: $element.fontSize, in: 8...96, step: 2)
                    Picker("Font", selection: $element.fontDesign) {
                        ForEach(PageElement.FontDesign.allCases) { Text($0.displayName).tag($0) }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(tools.palette, id: \.self) { hex in
                                Button { element.colorHex = hex } label: {
                                    ColorSwatch(hex: hex, isSelected: element.colorHex == hex)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Text" : (element.kind == .link ? "Edit Link" : "Edit Text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(element)
                        dismiss()
                    }
                    .accessibilityIdentifier("saveText")
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// Shows handwriting recognised by Vision and lets the user insert it as text.
struct RecognitionResultSheet: View {
    @State private var text: String
    let onInsert: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    init(text: String, onInsert: @escaping (String, Bool) -> Void) {
        self.text = text
        self.onInsert = onInsert
    }

    var body: some View {
        NavigationStack {
            Form {
                if text.isEmpty {
                    ContentUnavailableView("No Text Recognized", systemImage: "character.magnify",
                                           description: Text("Try selecting clearer handwriting, or type the text below."))
                }
                Section("Recognized Text") {
                    TextEditor(text: $text).frame(minHeight: 140)
                }
                Section {
                    Button("Replace Handwriting with Text") { onInsert(text, true); dismiss() }
                        .disabled(text.isEmpty)
                    Button("Add Text and Keep Handwriting") { onInsert(text, false); dismiss() }
                        .disabled(text.isEmpty)
                    Button("Copy Text") { UIPasteboard.general.string = text; dismiss() }
                        .disabled(text.isEmpty)
                }
            }
            .navigationTitle("Convert to Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Picks a page of the current notebook to link to.
struct LinkPickerSheet: View {
    let pages: [Page]
    let currentPageID: UUID?
    let onPick: (Page) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        onPick(page)
                        dismiss()
                    } label: {
                        HStack {
                            PageThumbnailView(page: page, width: 44)
                            VStack(alignment: .leading) {
                                Text(page.displayTitle(index: index))
                                if page.isBookmarked { Label("Bookmarked", systemImage: "bookmark.fill").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    .disabled(page.id == currentPageID)
                }
            }
            .navigationTitle("Link to Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
