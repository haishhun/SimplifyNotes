import os
import Foundation
import PencilKit

/// Everything stored for a page outside the database.
nonisolated struct PageContent: Sendable {
    var drawing: PKDrawing
    var elements: [PageElement]
    /// True when the primary file was unreadable and the previous version was restored.
    var recoveredFromBackup: Bool = false

    static let empty = PageContent(drawing: PKDrawing(), elements: [])
}

/// Abstraction over page/asset storage. The editor and services only talk to this
/// protocol, so an iCloud-backed implementation (e.g. a ubiquity container with
/// `NSFileCoordinator`, or CKAsset uploads) can be swapped in without touching them.
nonisolated protocol PageContentStoring: AnyObject, Sendable {
    // Page content
    func loadContent(pageID: UUID) async -> PageContent
    func loadContentSync(pageID: UUID) -> PageContent
    /// Enqueues a write. Writes for the store are applied in FIFO order.
    func save(drawing: PKDrawing, pageID: UUID)
    func save(elements: [PageElement], pageID: UUID)
    /// Writes content immediately (used when creating pages from snapshots).
    func write(content: PageContent, pageID: UUID) throws
    func duplicateContent(from source: UUID, to destination: UUID)
    func deleteContent(pageIDs: [UUID])
    /// Blocks until all pending writes have reached disk.
    func flush()

    // Assets
    func importAsset(data: Data, fileExtension: String) throws -> String
    func assetURL(named name: String) -> URL
    func importPDF(from url: URL) throws -> String
    func pdfURL(named name: String) -> URL
    func deletePDF(named name: String)
    func newAudioFileURL() -> (name: String, url: URL)
    func audioURL(named name: String) -> URL
    func deleteAudio(named name: String)
    func collectUnreferencedAssets(keeping referenced: Set<String>)
    func storageSize() -> Int64
}

/// File-system implementation.
///
/// Layout (inside Application Support/Inkwell):
/// ```
/// Pages/<uuid>/ink.drawing        PencilKit data
/// Pages/<uuid>/ink.drawing.bak    previous version (crash safety)
/// Pages/<uuid>/elements.json      text boxes, images, links
/// Assets/<uuid>.<ext>             immutable image assets
/// Documents/<uuid>.pdf            imported PDFs (original, untouched)
/// Audio/<uuid>.m4a                recordings
/// ```
nonisolated final class FilePageContentStore: PageContentStoring, @unchecked Sendable {
    let rootURL: URL
    private let fileManager = FileManager.default
    /// Serial queue: guarantees writes land in the order they were requested and
    /// that reads observe every write enqueued before them.
    private let queue = DispatchQueue(label: "com.inkwell.storage", qos: .userInitiated)

    private var pagesURL: URL { rootURL.appending(path: "Pages", directoryHint: .isDirectory) }
    private var assetsURL: URL { rootURL.appending(path: "Assets", directoryHint: .isDirectory) }
    private var documentsURL: URL { rootURL.appending(path: "Documents", directoryHint: .isDirectory) }
    private var audioDirURL: URL { rootURL.appending(path: "Audio", directoryHint: .isDirectory) }

    init(rootURL: URL) {
        self.rootURL = rootURL
        for dir in [pagesURL, assetsURL, documentsURL, audioDirURL] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Folder name kept from the app's original name so existing notes stay where they are.
        return base.appending(path: "Inkwell", directoryHint: .isDirectory)
    }

    // MARK: Paths

    private func pageDirectory(_ id: UUID) -> URL {
        pagesURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    func drawingURL(_ id: UUID) -> URL { pageDirectory(id).appending(path: "ink.drawing") }
    func elementsURL(_ id: UUID) -> URL { pageDirectory(id).appending(path: "elements.json") }

    // MARK: Loading

    func loadContent(pageID: UUID) async -> PageContent {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readContent(pageID: pageID))
            }
        }
    }

    func loadContentSync(pageID: UUID) -> PageContent {
        queue.sync { readContent(pageID: pageID) }
    }

    /// Must run on `queue`.
    private func readContent(pageID: UUID) -> PageContent {
        var recovered = false
        let drawing: PKDrawing = readWithBackup(at: drawingURL(pageID), recovered: &recovered) { data in
            try PKDrawing(data: data)
        } ?? PKDrawing()
        let elements: [PageElement] = readWithBackup(at: elementsURL(pageID), recovered: &recovered) { data in
            try JSONDecoder().decode([PageElement].self, from: data)
        } ?? []
        if recovered {
            Log.storage.error("Recovered page \(pageID) from backup after a failed read")
        }
        return PageContent(drawing: drawing, elements: elements, recoveredFromBackup: recovered)
    }

    private func readWithBackup<T>(at url: URL, recovered: inout Bool, decode: (Data) throws -> T) -> T? {
        if let data = try? Data(contentsOf: url) {
            if let value = try? decode(data) { return value }
            Log.storage.error("Corrupt file at \(url.lastPathComponent, privacy: .public)")
        }
        let backup = backupURL(for: url)
        if let data = try? Data(contentsOf: backup), let value = try? decode(data) {
            // Only a recovery if the primary was expected to exist.
            recovered = true
            return value
        }
        return nil
    }

    private func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    // MARK: Writing

    func save(drawing: PKDrawing, pageID: UUID) {
        queue.async {
            // Serialisation happens here, off the main thread.
            let data = drawing.dataRepresentation()
            self.safeWrite(data, to: self.drawingURL(pageID), pageID: pageID)
        }
    }

    func save(elements: [PageElement], pageID: UUID) {
        queue.async {
            do {
                let data = try JSONEncoder().encode(elements)
                self.safeWrite(data, to: self.elementsURL(pageID), pageID: pageID)
            } catch {
                Log.storage.error("Encoding elements failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func write(content: PageContent, pageID: UUID) throws {
        var thrown: Error?
        queue.sync {
            do {
                try self.ensurePageDirectory(pageID)
                try content.drawing.dataRepresentation().write(to: self.drawingURL(pageID), options: .atomic)
                try JSONEncoder().encode(content.elements).write(to: self.elementsURL(pageID), options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw AppError.saveFailed(thrown.localizedDescription) }
    }

    /// Keeps the last good version as `.bak`, then writes atomically
    /// (temp file + rename), so an interruption never leaves a half-written file.
    private func safeWrite(_ data: Data, to url: URL, pageID: UUID) {
        do {
            try ensurePageDirectory(pageID)
            let backup = backupURL(for: url)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: backup)
                try? fileManager.copyItem(at: url, to: backup)
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.storage.error("Write failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensurePageDirectory(_ id: UUID) throws {
        let dir = pageDirectory(id)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func duplicateContent(from source: UUID, to destination: UUID) {
        queue.async {
            let src = self.pageDirectory(source)
            let dst = self.pageDirectory(destination)
            guard self.fileManager.fileExists(atPath: src.path) else { return }
            try? self.fileManager.removeItem(at: dst)
            do {
                try self.fileManager.copyItem(at: src, to: dst)
            } catch {
                Log.storage.error("Duplicate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func deleteContent(pageIDs: [UUID]) {
        queue.async {
            for id in pageIDs {
                try? self.fileManager.removeItem(at: self.pageDirectory(id))
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    // MARK: Assets

    func importAsset(data: Data, fileExtension: String) throws -> String {
        let name = "\(UUID().uuidString).\(fileExtension)"
        do {
            try data.write(to: assetURL(named: name), options: .atomic)
        } catch {
            throw AppError.saveFailed(error.localizedDescription)
        }
        return name
    }

    func assetURL(named name: String) -> URL { assetsURL.appending(path: name) }

    func importPDF(from url: URL) throws -> String {
        let name = "\(UUID().uuidString).pdf"
        let destination = pdfURL(named: name)
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw AppError.saveFailed(error.localizedDescription)
        }
        return name
    }

    func pdfURL(named name: String) -> URL { documentsURL.appending(path: name) }

    func deletePDF(named name: String) {
        try? fileManager.removeItem(at: pdfURL(named: name))
    }

    func newAudioFileURL() -> (name: String, url: URL) {
        let name = "\(UUID().uuidString).m4a"
        return (name, audioURL(named: name))
    }

    func audioURL(named name: String) -> URL { audioDirURL.appending(path: name) }

    func deleteAudio(named name: String) {
        try? fileManager.removeItem(at: audioURL(named: name))
    }

    /// Removes image assets that no page references any more.
    func collectUnreferencedAssets(keeping referenced: Set<String>) {
        queue.async {
            guard let files = try? self.fileManager.contentsOfDirectory(atPath: self.assetsURL.path) else { return }
            for file in files where !referenced.contains(file) {
                try? self.fileManager.removeItem(at: self.assetsURL.appending(path: file))
            }
        }
    }

    func storageSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Reads all element files to find referenced assets. Runs on the storage queue.
    func referencedAssetNames(pageIDs: [UUID]) -> Set<String> {
        queue.sync {
            var names = Set<String>()
            for id in pageIDs {
                guard let data = try? Data(contentsOf: elementsURL(id)),
                      let elements = try? JSONDecoder().decode([PageElement].self, from: data) else { continue }
                for element in elements { if let name = element.assetName { names.insert(name) } }
            }
            return names
        }
    }
}
