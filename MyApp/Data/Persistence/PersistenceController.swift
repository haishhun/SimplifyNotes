import os
import Foundation
import SwiftData

/// Creates the SwiftData container. Metadata only — drawings and PDFs are files.
enum PersistenceController {
    static let schema = Schema([Subject.self, Notebook.self, Page.self, AudioRecording.self, TemplatePreset.self])

    /// Result of opening the on-disk store.
    struct OpenResult {
        let container: ModelContainer
        /// Set when the existing store couldn't be opened and was moved aside.
        let recoveryMessage: String?
    }

    static func makeContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // `cloudKitDatabase: .none` today; switching to `.automatic` enables sync
            // because the schema already follows CloudKit's rules.
            configuration = ModelConfiguration(schema: schema,
                                               url: storeURL ?? defaultStoreURL(),
                                               cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func defaultStoreURL() -> URL {
        FilePageContentStore.defaultRoot().appending(path: "Library.store")
    }

    /// Opens the persistent store. If it is unreadable, the damaged store is moved
    /// aside (never deleted) and a fresh one is created so the app stays usable.
    static func openPersistentStore() -> OpenResult {
        let url = defaultStoreURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return OpenResult(container: try makeContainer(storeURL: url), recoveryMessage: nil)
        } catch {
            Log.storage.fault("Store failed to open: \(error.localizedDescription, privacy: .public)")
            let stamp = Int(Date.now.timeIntervalSince1970)
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                let destination = URL(fileURLWithPath: url.path + ".damaged-\(stamp)" + suffix)
                try? fm.moveItem(at: source, to: destination)
            }
            do {
                let container = try makeContainer(storeURL: url)
                return OpenResult(container: container,
                                  recoveryMessage: "Your library database was damaged and has been set aside. Page files were kept.")
            } catch {
                // Last resort: in-memory so the UI can still show the error.
                let container = try! makeContainer(inMemory: true)
                return OpenResult(container: container,
                                  recoveryMessage: "SimplifyNotes couldn't open its library: \(error.localizedDescription)")
            }
        }
    }
}
