import SwiftUI
import PencilKit
import Observation

/// The tools available in the editor toolbar.
nonisolated enum ToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ballpoint, fountain, brush, pencil, highlighter, eraser, lasso, shapes, text, objects

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ballpoint: "Ballpoint"
        case .fountain: "Fountain Pen"
        case .brush: "Brush Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .shapes: "Shapes"
        case .text: "Text"
        case .objects: "Select Objects"
        }
    }

    var symbolName: String {
        switch self {
        case .ballpoint: "pencil.tip"
        case .fountain: "pencil.and.scribble"
        case .brush: "paintbrush.pointed"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .shapes: "square.on.circle"
        case .text: "textformat"
        case .objects: "hand.point.up.left"
        }
    }

    /// Tools that lay down ink.
    var isInking: Bool {
        switch self {
        case .ballpoint, .fountain, .brush, .pencil, .highlighter, .shapes: true
        default: false
        }
    }

    /// Whether the PencilKit drawing gesture is active for this tool.
    var usesCanvasDrawing: Bool { isInking || self == .eraser }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .ballpoint, .shapes: .monoline
        case .fountain: .fountainPen
        case .brush: .pen
        case .pencil: .pencil
        case .highlighter: .marker
        default: .pen
        }
    }

    var defaultPreset: InkPreset {
        switch self {
        case .ballpoint: InkPreset(colorHex: "#1C1C1E", width: 2.2, opacity: 1)
        case .fountain: InkPreset(colorHex: "#1D3A8A", width: 4, opacity: 1)
        case .brush: InkPreset(colorHex: "#1C1C1E", width: 7, opacity: 1)
        case .pencil: InkPreset(colorHex: "#3A3A3C", width: 3, opacity: 1)
        case .highlighter: InkPreset(colorHex: "#FFD43B", width: 18, opacity: 0.5)
        case .shapes: InkPreset(colorHex: "#1C1C1E", width: 2.4, opacity: 1)
        default: InkPreset(colorHex: "#1C1C1E", width: 2, opacity: 1)
        }
    }
}

nonisolated struct InkPreset: Codable, Hashable, Sendable {
    var colorHex: String
    var width: Double
    var opacity: Double
}

nonisolated enum EraserMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case stroke, pixel
    var id: String { rawValue }
    var displayName: String { self == .stroke ? "Stroke Eraser" : "Pixel Eraser" }
}

nonisolated enum ToolbarPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, bottom, leading, trailing
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var isVertical: Bool { self == .leading || self == .trailing }
}

/// Persisted tool state shared by all editors. Changes are written to
/// `UserDefaults` so the user's pens, colours and toolbar survive relaunches.
@Observable
final class ToolSettings {
    static let defaultPalette = ["#1C1C1E", "#1D3A8A", "#2F6FEB", "#2B8A3E", "#E03131", "#F08C00", "#7048E8", "#FFD43B"]

    var currentTool: ToolKind = .ballpoint { didSet { if oldValue != currentTool { previousTool = oldValue; persist() } } }
    private(set) var previousTool: ToolKind = .eraser
    var presets: [ToolKind: InkPreset] = [:] { didSet { persist() } }
    var eraserMode: EraserMode = .stroke { didSet { persist() } }
    var eraserWidth: Double = 16 { didSet { persist() } }
    var customColors: [String] = [] { didSet { persist() } }
    var toolbarPosition: ToolbarPosition = .top { didSet { persist() } }
    var visibleTools: [ToolKind] = ToolKind.allCases { didSet { persist() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false
    private static let key = "toolSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var palette: [String] { Self.defaultPalette + customColors }

    func preset(for tool: ToolKind) -> InkPreset {
        presets[tool] ?? tool.defaultPreset
    }

    func updatePreset(for tool: ToolKind, _ change: (inout InkPreset) -> Void) {
        var preset = preset(for: tool)
        change(&preset)
        presets[tool] = preset
    }

    var currentPreset: InkPreset { preset(for: currentTool) }

    /// Width bounds supported by PencilKit for the tool's ink.
    func widthRange(for tool: ToolKind) -> ClosedRange<Double> {
        if tool == .eraser { return 4...80 }
        let range = tool.inkType.validWidthRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    /// PencilKit tool for the current state; nil for non-drawing tools.
    func pkTool(for tool: ToolKind) -> PKTool? {
        if tool == .eraser {
            switch eraserMode {
            case .stroke: return PKEraserTool(.vector, width: eraserWidth)
            case .pixel: return PKEraserTool(.bitmap, width: eraserWidth)
            }
        }
        guard tool.isInking else { return nil }
        let preset = preset(for: tool)
        let color = UIColor(hex: preset.colorHex).withAlphaComponent(CGFloat(preset.opacity))
        let range = tool.inkType.validWidthRange
        let width = min(max(CGFloat(preset.width), range.lowerBound), range.upperBound)
        return PKInkingTool(tool.inkType, color: color, width: width)
    }

    func addCustomColor(_ hex: String) {
        guard !palette.contains(hex) else { return }
        customColors.append(hex)
    }

    func removeCustomColor(_ hex: String) {
        customColors.removeAll { $0 == hex }
    }

    func switchToPrevious() {
        let target = previousTool
        currentTool = target
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var currentTool: ToolKind
        var presets: [String: InkPreset]
        var eraserMode: EraserMode
        var eraserWidth: Double
        var customColors: [String]
        var toolbarPosition: ToolbarPosition
        var visibleTools: [ToolKind]
    }

    private func persist() {
        guard !isLoading else { return }
        let stored = Stored(currentTool: currentTool,
                            presets: Dictionary(uniqueKeysWithValues: presets.map { ($0.key.rawValue, $0.value) }),
                            eraserMode: eraserMode, eraserWidth: eraserWidth, customColors: customColors,
                            toolbarPosition: toolbarPosition, visibleTools: visibleTools)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        currentTool = stored.currentTool
        presets = Dictionary(uniqueKeysWithValues: stored.presets.compactMap { key, value in
            ToolKind(rawValue: key).map { ($0, value) }
        })
        eraserMode = stored.eraserMode
        eraserWidth = stored.eraserWidth
        customColors = stored.customColors
        toolbarPosition = stored.toolbarPosition
        visibleTools = stored.visibleTools.isEmpty ? ToolKind.allCases : stored.visibleTools
    }
}
