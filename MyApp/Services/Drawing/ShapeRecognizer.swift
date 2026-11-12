import CoreGraphics
import Foundation

/// A cleaned-up geometric shape. All variants are expressed as polylines
/// (one or more segments) so they can be turned into PencilKit strokes.
nonisolated enum RecognizedShape: Equatable, Sendable {
    case line(CGPoint, CGPoint)
    case arrow(tail: CGPoint, tip: CGPoint)
    case ellipse(CGRect)
    case rectangle([CGPoint])   // 4 corners in drawing order
    case triangle([CGPoint])    // 3 corners

    var name: String {
        switch self {
        case .line: "line"
        case .arrow: "arrow"
        case .ellipse: "ellipse"
        case .rectangle: "rectangle"
        case .triangle: "triangle"
        }
    }

    /// Polylines that make up the shape (arrow = shaft + head).
    var polylines: [[CGPoint]] {
        switch self {
        case .line(let a, let b):
            return [[a, b]]
        case .arrow(let tail, let tip):
            let angle = atan2(tip.y - tail.y, tip.x - tail.x)
            let length = min(max(tail.distance(to: tip) * 0.18, 10), 36)
            let spread = CGFloat.pi / 7
            let left = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
            let right = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
            return [[tail, tip], [left, tip, right]]
        case .ellipse(let rect):
            let steps = 72
            let points = (0...steps).map { i -> CGPoint in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                return CGPoint(x: rect.midX + rect.width / 2 * cos(t), y: rect.midY + rect.height / 2 * sin(t))
            }
            return [points]
        case .rectangle(let corners), .triangle(let corners):
            return [corners + [corners[0]]]
        }
    }
}

/// Recognises lines, arrows, ellipses/circles, rectangles and triangles from raw stroke points.
/// Pure and deterministic, so it is fully unit-tested.
nonisolated enum ShapeRecognizer {
    static func recognize(_ rawPoints: [CGPoint]) -> RecognizedShape? {
        guard rawPoints.count >= 2 else { return nil }
        let length = PolygonMath.pathLength(rawPoints)
        guard length > 24 else { return nil }
        let points = PolygonMath.resample(rawPoints, count: 64)
        guard let first = points.first, let last = points.last else { return nil }
        let bounds = PolygonMath.boundingBox(points)
        let diagonal = hypot(bounds.width, bounds.height)
        let isClosed = first.distance(to: last) < max(diagonal * 0.22, 12)

        if !isClosed {
            if let line = recognizeLine(points, length: PolygonMath.pathLength(points)) { return line }
            if let arrow = recognizeArrow(points) { return arrow }
            return nil
        }
        return recognizeClosed(points, bounds: bounds, diagonal: diagonal)
    }

    private static func recognizeLine(_ points: [CGPoint], length: CGFloat) -> RecognizedShape? {
        guard let first = points.first, let last = points.last else { return nil }
        let chord = first.distance(to: last)
        guard chord > 0, length / chord < 1.08 else { return nil }
        let maxDeviation = points.map { PolygonMath.distance(from: $0, toSegment: first, last) }.max() ?? 0
        guard maxDeviation < max(chord * 0.06, 3) else { return nil }
        return .line(first, snapEnd(from: first, to: last))
    }

    /// Single-stroke arrows: a shaft, then a barb drawn back from the tip and
    /// (optionally) back to the tip and out to the other side.
    private static func recognizeArrow(_ points: [CGPoint]) -> RecognizedShape? {
        let bounds = PolygonMath.boundingBox(points)
        let simplified = PolygonMath.simplify(points, epsilon: max(hypot(bounds.width, bounds.height) * 0.04, 2))
        guard simplified.count >= 3, simplified.count <= 6 else { return nil }
        let segments = zip(simplified, simplified.dropFirst()).map { $0.0.distance(to: $0.1) }
        guard let shaft = segments.first, shaft > 30 else { return nil }
        let tip = simplified[1]
        let head = segments.dropFirst()
        // Every head segment is short compared to the shaft…
        guard head.allSatisfy({ $0 < shaft * 0.6 }) else { return nil }
        // …and stays close to the tip.
        guard simplified.dropFirst(2).allSatisfy({ $0.distance(to: tip) < shaft * 0.6 }) else { return nil }
        // The first barb must point backwards relative to the shaft.
        let shaftVector = tip - simplified[0]
        let barbVector = simplified[2] - tip
        let dot = shaftVector.x * barbVector.x + shaftVector.y * barbVector.y
        guard dot < 0 else { return nil }
        return .arrow(tail: simplified[0], tip: tip)
    }

    private static func recognizeClosed(_ points: [CGPoint], bounds: CGRect, diagonal: CGFloat) -> RecognizedShape? {
        guard bounds.width > 12, bounds.height > 12 else { return nil }
        var closedPoints = points
        if let first = points.first { closedPoints.append(first) }

        // Corner detection on the closed polygon.
        let simplified = PolygonMath.simplify(closedPoints, epsilon: diagonal * 0.07)
        var corners = Array(simplified.dropLast())
        corners = mergeCloseCorners(corners, threshold: diagonal * 0.12)
        // Ellipse fit: radial variance around the bounding-box ellipse.
        let ellipseError = ellipseResidual(points, bounds: bounds)

        if corners.count == 3, ellipseError > 0.09 {
            return .triangle(corners)
        }
        if corners.count == 4, ellipseError > 0.07 {
            return .rectangle(regularizeQuad(corners))
        }
        if ellipseError < 0.14 {
            // Snap near-circles to perfect circles.
            var rect = bounds
            let ratio = bounds.width / bounds.height
            if ratio > 0.85 && ratio < 1.18 {
                let side = (bounds.width + bounds.height) / 2
                rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            }
            return .ellipse(rect)
        }
        return nil
    }

    /// Mean normalised distance of points from the ellipse inscribed in `bounds`.
    static func ellipseResidual(_ points: [CGPoint], bounds: CGRect) -> CGFloat {
        let rx = bounds.width / 2, ry = bounds.height / 2
        guard rx > 0, ry > 0 else { return .infinity }
        let c = bounds.center
        let errors = points.map { p -> CGFloat in
            let dx = (p.x - c.x) / rx, dy = (p.y - c.y) / ry
            return abs(sqrt(dx * dx + dy * dy) - 1)
        }
        return errors.reduce(0, +) / CGFloat(errors.count)
    }

    private static func mergeCloseCorners(_ corners: [CGPoint], threshold: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = []
        for corner in corners {
            if let last = result.last, last.distance(to: corner) < threshold { continue }
            result.append(corner)
        }
        if result.count > 1, let first = result.first, let last = result.last, first.distance(to: last) < threshold {
            result.removeLast()
        }
        return result
    }

    /// Turns a rough quadrilateral into a clean rectangle: axis-aligned when the
    /// sides are within ~12° of horizontal/vertical, otherwise a rotated rectangle.
    private static func regularizeQuad(_ c: [CGPoint]) -> [CGPoint] {
        let angle = atan2(c[1].y - c[0].y, c[1].x - c[0].x)
        let normalized = abs(remainder(angle, .pi / 2))
        if normalized < .pi / 15 {
            let box = PolygonMath.boundingBox(c)
            return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        }
        // Rotated rectangle: project corners on the dominant axes.
        let center = CGPoint(x: c.map(\.x).reduce(0, +) / 4, y: c.map(\.y).reduce(0, +) / 4)
        let cosA = cos(-angle), sinA = sin(-angle)
        let local = c.map { p -> CGPoint in
            let d = p - center
            return CGPoint(x: d.x * cosA - d.y * sinA, y: d.x * sinA + d.y * cosA)
        }
        let box = PolygonMath.boundingBox(local)
        let cosB = cos(angle), sinB = sin(angle)
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { p in
            CGPoint(x: center.x + p.x * cosB - p.y * sinB, y: center.y + p.x * sinB + p.y * cosB)
        }
    }

    /// Snaps nearly horizontal / vertical / 45° lines exactly onto that angle.
    private static func snapEnd(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        guard abs(snapped - angle) < .pi / 36 else { return b }   // within 5°
        let length = a.distance(to: b)
        return CGPoint(x: a.x + length * cos(snapped), y: a.y + length * sin(snapped))
    }
}
