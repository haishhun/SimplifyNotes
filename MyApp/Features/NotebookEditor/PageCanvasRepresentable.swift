import SwiftUI

/// Bridges the UIKit canvas into SwiftUI. `updateUIView` is intentionally empty:
/// the view model talks to the canvas directly, so SwiftUI updates never touch
/// the drawing surface while the user writes.
struct PageCanvasRepresentable: UIViewRepresentable {
    let viewModel: NotebookEditorViewModel

    func makeUIView(context: Context) -> PageCanvasController {
        let controller = PageCanvasController()
        // Attach after the current update pass to avoid mutating state during view updates.
        Task { @MainActor in viewModel.attach(controller) }
        return controller
    }

    func updateUIView(_ uiView: PageCanvasController, context: Context) {}
}
