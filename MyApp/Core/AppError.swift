import Foundation
import os

/// User-facing errors. Every message explains what happened and what the user can do.
nonisolated enum AppError: LocalizedError, Equatable {
    case fileAccessDenied(String)
    case unreadablePDF(String)
    case encryptedPDF(String)
    case emptyPDF(String)
    case saveFailed(String)
    case exportFailed(String)
    case nothingToExport
    case imageUnreadable
    case microphoneDenied
    case recordingFailed(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let name):
            "SimplifyNotes couldn't access “\(name)”. Try importing it again from the Files app."
        case .unreadablePDF(let name):
            "“\(name)” isn't a valid PDF document or is damaged."
        case .encryptedPDF(let name):
            "“\(name)” is password protected. Remove the password in another app and import it again."
        case .emptyPDF(let name):
            "“\(name)” doesn't contain any pages."
        case .saveFailed(let detail):
            "Your changes couldn't be saved: \(detail)"
        case .exportFailed(let detail):
            "The PDF couldn't be created: \(detail)"
        case .nothingToExport:
            "Select at least one page to export."
        case .imageUnreadable:
            "That image couldn't be read."
        case .microphoneDenied:
            "Microphone access is off. Enable it for SimplifyNotes in Settings to record audio notes."
        case .recordingFailed(let detail):
            "Recording failed: \(detail)"
        case .recognitionFailed(let detail):
            "Handwriting couldn't be recognized: \(detail)"
        }
    }
}

nonisolated enum Log {
    static let storage = Logger(subsystem: "com.inkwell.app", category: "storage")
    static let editor = Logger(subsystem: "com.inkwell.app", category: "editor")
    static let pdf = Logger(subsystem: "com.inkwell.app", category: "pdf")
    static let services = Logger(subsystem: "com.inkwell.app", category: "services")
}
