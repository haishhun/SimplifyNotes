import UIKit

/// Limits how many expensive jobs run at once so background rendering never
/// competes with live inking for CPU.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Two-level (memory + disk) thumbnail cache. Keys include the page's
/// `contentVersion`, so edits invalidate automatically without explicit purges.
nonisolated final class ThumbnailService: @unchecked Sendable {
    private let store: PageContentStoring
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let limiter = AsyncLimiter(limit: 2)

    init(store: PageContentStoring, directory: URL? = nil) {
        self.store = store
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        memory.totalCostLimit = 64 * 1024 * 1024
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func key(_ snapshot: PageRenderSnapshot, width: Int) -> String {
        "\(snapshot.pageID.uuidString)-\(width)-\(snapshot.contentVersion)-\(snapshot.style.stableHash)-\(Int(snapshot.size.width))x\(Int(snapshot.size.height))"
    }

    private func pageFolder(_ id: UUID) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Synchronous memory lookup so cells can show cached images on first layout.
    func cachedThumbnail(for snapshot: PageRenderSnapshot, pixelWidth: CGFloat) -> UIImage? {
        memory.object(forKey: key(snapshot, width: Int(pixelWidth)) as NSString)
    }

    @concurrent
    func thumbnail(for snapshot: PageRenderSnapshot, pixelWidth: CGFloat) async -> UIImage? {
        let width = Int(pixelWidth)
        let cacheKey = key(snapshot, width: width)
        if let image = memory.object(forKey: cacheKey as NSString) { return image }

        let fileURL = pageFolder(snapshot.pageID).appending(path: "\(cacheKey).jpg")
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            memory.setObject(image, forKey: cacheKey as NSString, cost: data.count)
            return image
        }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }

        let content = await store.loadContent(pageID: snapshot.pageID)
        let image = PageRenderer.image(snapshot, content: content, assetURL: store.assetURL(named:),
                                       pixelWidth: CGFloat(width))
        let cost = Int(image.size.width * image.size.height * 4)
        memory.setObject(image, forKey: cacheKey as NSString, cost: cost)
        persist(image, to: fileURL, pageID: snapshot.pageID)
        return image
    }

    private func persist(_ image: UIImage, to url: URL, pageID: UUID) {
        let folder = pageFolder(pageID)
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Drop stale versions for this page/width.
        let prefix = url.lastPathComponent.split(separator: "-").prefix(6).joined(separator: "-")
        if let files = try? fm.contentsOfDirectory(atPath: folder.path) {
            for file in files where file.hasPrefix(prefix) && file != url.lastPathComponent {
                try? fm.removeItem(at: folder.appending(path: file))
            }
        }
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func removeThumbnails(for pageIDs: [UUID]) {
        for id in pageIDs {
            try? FileManager.default.removeItem(at: pageFolder(id))
        }
    }

    func clearMemory() { memory.removeAllObjects() }
}
