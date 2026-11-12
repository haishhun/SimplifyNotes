import PencilKit
import UIKit

/// Helpers for building, analysing and transforming PencilKit strokes.
nonisolated enum StrokeTools {
    /// Points of a stroke in drawing coordinates (stroke transform applied).
    static func points(of stroke: PKStroke, maxCount: Int = 400) -> [CGPoint] {
        let path = stroke.path
        guard !path.isEmpty else { return [] }
        let step = max(1, path.count / maxCount)
        var result: [CGPoint] = []
        result.reserveCapacity(min(path.count, maxCount) + 1)
        var index = 0
        while index < path.count {
            result.append(path[index].location.applying(stroke.transform))
            index += step
        }
        if let last = path.last { result.append(last.location.applying(stroke.transform)) }
        return result
    }

    /// Seconds the pen rested at the end of the stroke before lifting.
    /// Used for "draw and hold" automatic shape correction.
    static func endHoldDuration(of stroke: PKStroke, radius: CGFloat = 5) -> TimeInterval {
        let path = stroke.path
        guard let last = path.last else { return 0 }
        var earliest = last.timeOffset
        for index in stride(from: path.count - 1, through: 0, by: -1) {
            let point = path[index]
            if point.location.distance(to: last.location) > radius { break }
            earliest = point.timeOffset
        }
        return last.timeOffset - earliest
    }

    /// Builds clean strokes for a recognised shape using the original stroke's ink.
    static func strokes(for shape: RecognizedShape, like original: PKStroke) -> [PKStroke] {
        let path = original.path
        let sizes = path.map(\.size.width)
        let averageWidth = sizes.isEmpty ? 2 : sizes.reduce(0, +) / CGFloat(sizes.count)
        let width = max(averageWidth, 1)
        let opacity = path.first?.opacity ?? 1
        return shape.polylines.map { polyline in
            let dense = densify(polyline, spacing: 3)
            let controlPoints = dense.enumerated().map { index, location in
                PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.005,
                              size: CGSize(width: width, height: width), opacity: opacity,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let strokePath = PKStrokePath(controlPoints: controlPoints, creationDate: original.path.creationDate)
            return PKStroke(ink: original.ink, path: strokePath)
        }
    }

    /// Inserts intermediate points so straight segments render with even width.
    static func densify(_ polyline: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard polyline.count > 1 else { return polyline }
        var result: [CGPoint] = []
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let steps = max(1, Int(a.distance(to: b) / spacing))
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = polyline.last { result.append(last) }
        return result
    }

    /// Indices of strokes enclosed by a lasso polygon (≥ 60 % of sampled points inside).
    static func strokesInside(_ polygon: [CGPoint], drawing: PKDrawing) -> IndexSet {
        guard polygon.count > 2 else { return [] }
        let lassoBounds = PolygonMath.boundingBox(polygon)
        var selected = IndexSet()
        for (index, stroke) in drawing.strokes.enumerated() {
            guard stroke.renderBounds.intersects(lassoBounds) else { continue }
            let samples = points(of: stroke, maxCount: 40)
            guard !samples.isEmpty else { continue }
            let inside = samples.filter { PolygonMath.contains(polygon, point: $0) }.count
            if Double(inside) / Double(samples.count) >= 0.6 { selected.insert(index) }
        }
        return selected
    }

    static func bounds(of strokes: [PKStroke]) -> CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
    }

    static func recolored(_ stroke: PKStroke, color: UIColor) -> PKStroke {
        var copy = stroke
        copy.ink = PKInk(stroke.ink.inkType, color: color)
        return copy
    }

    /// Applies `transform` by rewriting the stroke's control points (the result has an
    /// identity `transform`). Keeping transforms on `PKStroke.transform` made the reported
    /// bounds disagree with what PencilKit draws, so selections drifted after a resize.
    /// Point sizes scale with the transform, so resized handwriting keeps its proportions.
    static func transformed(_ stroke: PKStroke, by transform: CGAffineTransform) -> PKStroke {
        let full = stroke.transform.concatenating(transform)
        let scale = sqrt(abs(full.a * full.d - full.b * full.c))
        let rotation = atan2(full.b, full.a)
        let controlPoints = stroke.path.map { point in
            PKStrokePoint(location: point.location.applying(full),
                          timeOffset: point.timeOffset,
                          size: CGSize(width: point.size.width * scale, height: point.size.height * scale),
                          opacity: point.opacity,
                          force: point.force,
                          azimuth: point.azimuth + rotation,
                          altitude: point.altitude,
                          secondaryScale: point.secondaryScale,
                          threshold: point.threshold,
                          lateralJitter: point.lateralJitter)
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: stroke.path.creationDate)
        var mask: UIBezierPath?
        if let original = stroke.mask {
            let copy = original.copy() as? UIBezierPath ?? UIBezierPath(cgPath: original.cgPath)
            copy.apply(full)
            mask = copy
        }
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: mask)
    }
}
