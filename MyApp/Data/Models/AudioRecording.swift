import Foundation
import SwiftData

/// An audio note recorded while a notebook was open. The audio itself is a file.
@Model
final class AudioRecording {
    var id: UUID = UUID()
    var title: String = ""
    var fileName: String = ""
    var createdAt: Date = Date.now
    var duration: Double = 0
    /// Page that was visible when recording started.
    var pageID: UUID?
    var notebook: Notebook?

    init(title: String, fileName: String, duration: Double, pageID: UUID?) {
        self.id = UUID()
        self.title = title
        self.fileName = fileName
        self.duration = duration
        self.pageID = pageID
        self.createdAt = .now
    }
}

/// A user-defined page template ("Custom templates").
@Model
final class TemplatePreset {
    var id: UUID = UUID()
    var name: String = ""
    var styleData: Data = Data()
    var createdAt: Date = Date.now

    init(name: String, style: PageStyle) {
        self.id = UUID()
        self.name = name
        self.styleData = style.encoded()
        self.createdAt = .now
    }

    var style: PageStyle { PageStyle.decode(styleData) ?? .default }
}
