import SwiftUI
import SwiftData

/// Create a notebook, or rename/recolor/re-file an existing one.
struct NotebookEditorSheet: View {
    enum Mode {
        case create(subject: Subject?)
        case edit(Notebook)
    }

    let mode: Mode
    let onCreated: (Notebook) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Subject.sortIndex) private var subjects: [Subject]
    @State private var title = ""
    @State private var colorHex = Theme.Colors.subjectChoices[0]
    @State private var subjectID: UUID?
    @State private var style = PageStyle.default
    @State private var didLoad = false

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notebook title", text: $title)
                        .font(.title3)
                        .accessibilityIdentifier("notebookTitleField")
                        .submitLabel(.done)
                        .onSubmit(save)
                }
                Section("Subject") {
                    Picker("Subject", selection: $subjectID) {
                        Text("Unfiled").tag(UUID?.none)
                        ForEach(subjects) { subject in
                            Label(subject.name, systemImage: subject.symbolName).tag(Optional(subject.id))
                        }
                    }
                }
                Section("Cover") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                        ForEach(Theme.Colors.subjectChoices, id: \.self) { hex in
                            Button { colorHex = hex } label: { ColorSwatch(hex: hex, isSelected: hex == colorHex, size: 32) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if isCreating {
                    Section("Paper") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(PaperTemplate.allCases) { template in
                                    Button {
                                        style.template = template
                                        style.spacing = template.defaultSpacing
                                    } label: {
                                        VStack {
                                            PaperPreview(style: PageStyle(template: template, marginTop: 40, marginLeft: 50))
                                                .frame(height: 90)
                                                .overlay(RoundedRectangle(cornerRadius: 4)
                                                    .strokeBorder(style.template == template ? Color.accentColor : .clear, lineWidth: 2.5))
                                            Text(template.displayName).font(.caption)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(template.displayName)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        Picker("Size", selection: $style.paperSize) {
                            ForEach(PaperSize.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Orientation", selection: $style.orientation) {
                            ForEach(PaperOrientation.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(isCreating ? "New Notebook" : "Edit Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Save", action: save)
                        .accessibilityIdentifier("saveNotebook")
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .create(let subject):
            subjectID = subject?.id
            colorHex = subject?.colorHex ?? colorHex
            style = env.settings.defaultStyle
        case .edit(let notebook):
            title = notebook.title
            colorHex = notebook.coverColorHex
            subjectID = notebook.subject?.id
        }
    }

    private func save() {
        let subject = subjects.first { $0.id == subjectID }
        switch mode {
        case .create:
            env.perform {
                let notebook = try env.repository.createNotebook(title: title, subject: subject, coverColorHex: colorHex, style: style)
                dismiss()
                onCreated(notebook)
            }
        case .edit(let notebook):
            env.perform {
                try env.repository.renameNotebook(notebook, to: title)
                try env.repository.updateNotebookAppearance(notebook, coverColorHex: colorHex)
                try env.repository.moveNotebook(notebook, to: subject)
                dismiss()
            }
        }
    }
}
