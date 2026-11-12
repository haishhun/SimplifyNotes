import SwiftUI
import SwiftData
import Observation

/// Dependency container created once at launch and injected through the SwiftUI environment.
@Observable
final class AppEnvironment {
    let container: ModelContainer
    let store: PageContentStoring
    let repository: LibraryRepository
    let thumbnails: ThumbnailService
    let tools: ToolSettings
    let settings: AppSettings
    let audio: AudioNoteService
    /// Pages copied with "Copy" in the page overview, pasteable into any notebook.
    var pageClipboard: [PageSnapshot] = []
    /// Shown once if the database had to be recovered.
    var startupMessage: String?
    /// Errors surfaced to the user by any feature.
    var presentedError: String?

    init(container: ModelContainer, store: PageContentStoring, defaults: UserDefaults = .standard, startupMessage: String? = nil) {
        self.container = container
        self.store = store
        self.repository = LibraryRepository(context: container.mainContext, store: store)
        self.thumbnails = ThumbnailService(store: store)
        self.tools = ToolSettings(defaults: defaults)
        self.settings = AppSettings(defaults: defaults)
        self.audio = AudioNoteService()
        self.startupMessage = startupMessage
    }

    static func live() -> AppEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        // UI tests launch with a clean, in-memory library for determinism.
        if arguments.contains("-uiTesting") {
            let root = FileManager.default.temporaryDirectory.appending(path: "UITest-\(UUID().uuidString)")
            let defaults = UserDefaults(suiteName: "uitest-\(UUID().uuidString)") ?? .standard
            let container = (try? PersistenceController.makeContainer(inMemory: true))
                ?? PersistenceController.openPersistentStore().container
            return AppEnvironment(container: container, store: FilePageContentStore(rootURL: root), defaults: defaults)
        }
        let result = PersistenceController.openPersistentStore()
        let environment = AppEnvironment(container: result.container,
                                         store: FilePageContentStore(rootURL: FilePageContentStore.defaultRoot()),
                                         startupMessage: result.recoveryMessage)
        environment.repository.collectGarbage()
        return environment
    }

    /// Runs a throwing action and reports failures to the user instead of dropping them.
    func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    /// Persists everything synchronously. Called when the app is backgrounded.
    func flushAll() {
        store.flush()
        try? repository.save()
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment: AppEnvironment? = nil
}
