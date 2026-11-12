import SwiftUI

/// Create or edit a subject (name, colour, icon).
struct SubjectEditorSheet: View {
    enum Mode: Identifiable {
        case create
        case edit(Subject)
        var id: String {
            switch self {
            case .create: "create"
            case .edit(let subject): subject.id.uuidString
            }
        }
    }

    let mode: Mode
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = Theme.Colors.subjectChoices[0]
    @State private var symbol = Theme.subjectSymbols[0]
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Subject name (e.g. Linear Algebra)", text: $name)
                        .accessibilityIdentifier("subjectNameField")
                        .submitLabel(.done)
                        .onSubmit(saveSubject)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                        ForEach(Theme.Colors.subjectChoices, id: \.self) { hex in
                            Button { colorHex = hex } label: { ColorSwatch(hex: hex, isSelected: hex == colorHex, size: 32) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                        ForEach(Theme.subjectSymbols, id: \.self) { name in
                            Button { symbol = name } label: {
                                Image(systemName: name)
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(symbol == name ? Color.white : Color(hex: colorHex))
                                    .background(symbol == name ? Color(hex: colorHex) : .clear, in: .rect(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(isCreate ? "New Subject" : "Edit Subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveSubject)
                    .accessibilityIdentifier("saveSubject")
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                if case .edit(let subject) = mode {
                    name = subject.name
                    colorHex = subject.colorHex
                    symbol = subject.symbolName
                }
            }
        }
    }

    private func saveSubject() {
        env.perform {
            switch mode {
            case .create: _ = try env.repository.createSubject(name: name, colorHex: colorHex, symbolName: symbol)
            case .edit(let subject): try env.repository.updateSubject(subject, name: name, colorHex: colorHex, symbolName: symbol)
            }
            dismiss()
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }
}
