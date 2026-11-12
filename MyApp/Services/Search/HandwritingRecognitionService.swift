import UIKit
import PencilKit
import Vision

/// On-device handwriting recognition with Vision. Used to index pages for search
/// and to convert lasso-selected ink into editable text.
nonisolated enum HandwritingRecognitionService {
    /// Recognises text in an ink drawing (rendered dark-on-white for best accuracy).
    @concurrent
    static func recognize(drawing: PKDrawing, in rect: CGRect? = nil) async throws -> String {
        let bounds = rect ?? drawing.bounds
        guard !drawing.strokes.isEmpty, !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return "" }
        let padded = bounds.insetBy(dx: -12, dy: -12)
        // Aim for ~2000 px on the long side, capped to keep memory predictable.
        let scale = min(max(2000 / max(padded.width, padded.height), 1), 3)
        guard let cgImage = render(drawing: drawing, rect: padded, scale: scale) else { return "" }
        return try await recognize(cgImage: cgImage)
    }

    @concurrent
    static func recognize(cgImage: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            let observations = try await request.perform(on: cgImage)
            return lines(from: observations).joined(separator: "\n")
        } catch {
            throw AppError.recognitionFailed(error.localizedDescription)
        }
    }

    /// Orders observations top-to-bottom, left-to-right (Vision uses a bottom-left origin).
    private static func lines(from observations: [RecognizedTextObservation]) -> [String] {
        observations
            .sorted { lhs, rhs in
                let l = lhs.boundingBox.cgRect, r = rhs.boundingBox.cgRect
                if abs(l.midY - r.midY) > min(l.height, r.height) * 0.5 { return l.midY > r.midY }
                return l.minX < r.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    static func render(drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return nil }
        var ink: UIImage?
        PageRenderer.lightTraits.performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ink?.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }
}
