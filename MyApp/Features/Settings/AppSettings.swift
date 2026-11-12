import SwiftUI
import Observation

nonisolated enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

nonisolated enum DrawingInputPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Follows the system "Only Draw with Apple Pencil" setting.
    case automatic
    case pencilOnly
    case anyInput
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .pencilOnly: "Apple Pencil Only"
        case .anyInput: "Pencil and Finger"
        }
    }
}

nonisolated enum DoubleTapAction: String, CaseIterable, Identifiable, Sendable {
    case system, eraser, previousTool, nothing
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: "Use System Setting"
        case .eraser: "Switch to Eraser"
        case .previousTool: "Switch to Previous Tool"
        case .nothing: "Do Nothing"
        }
    }
}

/// App-wide preferences backed by UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var appearance: AppearancePreference { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var inputPolicy: DrawingInputPolicy { didSet { defaults.set(inputPolicy.rawValue, forKey: "inputPolicy") } }
    var doubleTapAction: DoubleTapAction { didSet { defaults.set(doubleTapAction.rawValue, forKey: "doubleTap") } }
    var autoShapeCorrection: Bool { didSet { defaults.set(autoShapeCorrection, forKey: "autoShape") } }
    var handwritingIndexing: Bool { didSet { defaults.set(handwritingIndexing, forKey: "handwritingIndexing") } }
    var showPageSidebar: Bool { didSet { defaults.set(showPageSidebar, forKey: "showPageSidebar") } }
    var defaultStyleData: Data { didSet { defaults.set(defaultStyleData, forKey: "defaultStyle") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearancePreference(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        inputPolicy = DrawingInputPolicy(rawValue: defaults.string(forKey: "inputPolicy") ?? "") ?? .automatic
        doubleTapAction = DoubleTapAction(rawValue: defaults.string(forKey: "doubleTap") ?? "") ?? .system
        autoShapeCorrection = defaults.object(forKey: "autoShape") as? Bool ?? true
        handwritingIndexing = defaults.object(forKey: "handwritingIndexing") as? Bool ?? true
        showPageSidebar = defaults.object(forKey: "showPageSidebar") as? Bool ?? false
        defaultStyleData = defaults.data(forKey: "defaultStyle") ?? PageStyle.default.encoded()
    }

    var defaultStyle: PageStyle {
        get { PageStyle.decode(defaultStyleData) ?? .default }
        set { defaultStyleData = newValue.encoded() }
    }
}
