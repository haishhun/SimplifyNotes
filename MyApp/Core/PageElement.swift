import Foundation
import CoreGraphics

/// A non-ink object placed on a page: a text box, an image or an internal link.
/// Stored as JSON next to the page's drawing file.
nonisolated struct PageElement: Codable, Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case text, image, link
    }

    nonisolated enum FontDesign: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, serif, rounded, monospaced
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    var id: UUID = UUID()
    var kind: Kind
    /// Frame in page coordinates (points, origin at top-left), before rotation.
    var frame: CGRect
    /// Rotation around the frame's center, in radians.
    var rotation: Double = 0

    // Text & link label
    var text: String = ""
    var fontSize: Double = 18
    var colorHex: String = "#1C1C1E"
    var fontDesign: FontDesign = .standard

    // Image
    var assetName: String?

    // Link
    var targetPageID: UUID?

    static func textBox(at point: CGPoint, text: String = "", width: CGFloat = 260) -> PageElement {
        PageElement(kind: .text, frame: CGRect(x: point.x, y: point.y, width: width, height: 40), text: text)
    }

    static func image(assetName: String, frame: CGRect) -> PageElement {
        PageElement(kind: .image, frame: frame, assetName: assetName)
    }

    static func link(to pageID: UUID, label: String, at point: CGPoint) -> PageElement {
        PageElement(kind: .link, frame: CGRect(x: point.x, y: point.y, width: 200, height: 36),
                    text: label, fontSize: 15, colorHex: "#2F6FEB", targetPageID: pageID)
    }

    init(id: UUID = UUID(), kind: Kind, frame: CGRect, rotation: Double = 0, text: String = "",
         fontSize: Double = 18, colorHex: String = "#1C1C1E", fontDesign: FontDesign = .standard,
         assetName: String? = nil, targetPageID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.rotation = rotation
        self.text = text
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.fontDesign = fontDesign
        self.assetName = assetName
        self.targetPageID = targetPageID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        frame = try c.decode(CGRect.self, forKey: .frame)
        rotation = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 18
        colorHex = (try? c.decode(String.self, forKey: .colorHex)) ?? "#1C1C1E"
        fontDesign = (try? c.decode(FontDesign.self, forKey: .fontDesign)) ?? .standard
        assetName = try? c.decodeIfPresent(String.self, forKey: .assetName)
        targetPageID = try? c.decodeIfPresent(UUID.self, forKey: .targetPageID)
    }

    /// Axis-aligned bounds after applying rotation; used for hit-testing.
    var rotatedBounds: CGRect {
        guard rotation != 0 else { return frame }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: rotation)
            .translatedBy(x: -center.x, y: -center.y)
        return frame.applying(transform)
    }

    /// Precise hit test that honours rotation.
    func contains(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // Rotate the point into the element's local (unrotated) space.
        let dx = point.x - center.x, dy = point.y - center.y
        let cosR = cos(-rotation), sinR = sin(-rotation)
        let local = CGPoint(x: center.x + dx * cosR - dy * sinR, y: center.y + dx * sinR + dy * cosR)
        return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
    }
}
