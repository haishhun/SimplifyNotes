import SwiftData
import SwiftUI

/// Lists, plays, renames and deletes the notebook's audio recordings.
struct AudioNotesView: View {
    let viewModel: NotebookEditorViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: AudioRecording?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        viewModel.toggleRecording()
                    } label: {
                        HStack {
                            Image(systemName: env.audio.isRecording ? "stop.circle.fill" : "record.circle")
                                .font(.title2)
                                .foregroundStyle(.red)
                            if env.audio.isRecording, let start = env.audio.recordingStartedAt {
                                Text(start, style: .timer).monospacedDigit()
                                Text("Recording — keep writing").foregroundStyle(.secondary)
                            } else {
                                Text("Start Recording")
                            }
                        }
                    }
                }
                Section("Recordings") {
                    let recordings = viewModel.notebook.sortedRecordings
                    if recordings.isEmpty {
                        Text("No recordings yet. Audio notes stay with this notebook.").foregroundStyle(.secondary)
                    }
                    ForEach(recordings) { recording in
                        row(recording)
                    }
                }
            }
            .navigationTitle("Audio Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { env.perform { try env.repository.renameRecording(renaming, to: newTitle) } }
                    renaming = nil
                }
            }
        }
    }

    private func row(_ recording: AudioRecording) -> some View {
        let isPlaying = env.audio.playingRecordingID == recording.id
        return HStack {
            Button {
                env.perform { try env.audio.togglePlayback(of: recording, store: env.store) }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption).foregroundStyle(.secondary)
                if isPlaying {
                    ProgressView(value: env.audio.playbackProgress)
                }
            }
            Spacer()
            if let pageID = recording.pageID, viewModel.pages.contains(where: { $0.id == pageID }) {
                Button("Go to Page") {
                    viewModel.go(toPageID: pageID)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                if isPlaying { env.audio.stopPlayback() }
                env.perform { try env.repository.deleteRecording(recording) }
            }
            Button("Rename") { newTitle = recording.title; renaming = recording }
        }
    }
}

/// Search inside the open notebook (titles, handwriting, text boxes, PDF text).
struct EditorSearchView: View {
    let viewModel: NotebookEditorViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let results = SearchService(context: env.container.mainContext).search(query, in: viewModel.notebook)
            List {
                if query.isEmpty {
                    Text("Search page titles, handwriting, text boxes and PDF text in this notebook.")
                        .foregroundStyle(.secondary)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(results) { result in
                    Button {
                        if let page = result.page { viewModel.go(toPageID: page.id) }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Page \(result.pageNumber ?? 0)").font(.headline)
                            Text(result.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this notebook")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
