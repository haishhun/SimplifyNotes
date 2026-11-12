import SwiftUI

/// Opens a notebook (optionally at a specific page) in the full-screen editor.
struct EditorRoute: Identifiable {
    let id = UUID()
    let notebook: Notebook
    var pageID: UUID?
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var route: EditorRoute?

    var body: some View {
        @Bindable var env = env
        DashboardView(openNotebook: { notebook, pageID in route = EditorRoute(notebook: notebook, pageID: pageID) })
            .fullScreenCover(item: $route) { route in
                NotebookEditorView(notebook: route.notebook, env: env, initialPageID: route.pageID)
                    .environment(env)
                    .environment(env.tools)
                    .environment(env.settings)
            }
            .alert("Something Went Wrong", isPresented: Binding(get: { env.presentedError != nil },
                                                                set: { if !$0 { env.presentedError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(env.presentedError ?? "")
            }
            .alert("Library Recovered", isPresented: Binding(get: { env.startupMessage != nil },
                                                             set: { if !$0 { env.startupMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(env.startupMessage ?? "")
            }
    }
}
