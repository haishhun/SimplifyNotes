import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var storageSize: Int64?
    @State private var isEditingDefaultStyle = false

    var body: some View {
        @Bindable var settings = env.settings
        @Bindable var tools = env.tools
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppearancePreference.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Draw With", selection: $settings.inputPolicy) {
                        ForEach(DrawingInputPolicy.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Pencil Double-Tap", selection: $settings.doubleTapAction) {
                        ForEach(DoubleTapAction.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Draw and Hold to Correct Shapes", isOn: $settings.autoShapeCorrection)
                } header: {
                    Text("Apple Pencil")
                } footer: {
                    Text("With “Apple Pencil Only”, fingers scroll, zoom and use two-finger tap to undo (three fingers to redo). Pause at the end of a stroke to snap it into a line, arrow, circle, rectangle or triangle.")
                }
                Section {
                    Picker("Position", selection: $tools.toolbarPosition) {
                        ForEach(ToolbarPosition.allCases) { Text($0.displayName).tag($0) }
                    }
                    ForEach(ToolKind.allCases) { tool in
                        Toggle(isOn: Binding(get: { tools.visibleTools.contains(tool) }, set: { visible in
                            if visible {
                                tools.visibleTools = ToolKind.allCases.filter { tools.visibleTools.contains($0) || $0 == tool }
                            } else if tools.visibleTools.count > 1 {
                                tools.visibleTools.removeAll { $0 == tool }
                            }
                        })) {
                            Label(tool.displayName, systemImage: tool.symbolName)
                        }
                    }
                } header: {
                    Text("Toolbar")
                } footer: {
                    Text("You can also drag the toolbar to any edge of the screen.")
                }
                Section("New Notebooks") {
                    Button("Default Paper…") { isEditingDefaultStyle = true }
                    HStack {
                        Text("Current")
                        Spacer()
                        Text("\(settings.defaultStyle.template.displayName), \(settings.defaultStyle.paperSize.displayName)")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Index Handwriting for Search", isOn: $settings.handwritingIndexing)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Handwriting is recognized on device with Vision while you pause, never while you write.")
                }
                Section("Storage") {
                    HStack {
                        Text("Notes on This iPad")
                        Spacer()
                        if let storageSize {
                            Text(ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file)).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    Button("Clear Thumbnail Cache") { env.thumbnails.clearMemory() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $isEditingDefaultStyle) {
                PageStyleEditor(initialStyle: settings.defaultStyle, applyLabel: "Use for New Notebooks") { style in
                    settings.defaultStyle = style
                }
            }
            .task {
                let store = env.store
                storageSize = await Task.detached(priority: .utility) { store.storageSize() }.value
            }
        }
    }
}
