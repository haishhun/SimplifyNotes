import CoreGraphics
import Foundation

nonisolated extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
}

nonisolated extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Largest rect with the given aspect ratio that fits inside `self`, centered.
    func aspectFit(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return self }
        let scale = min(width / size.width, height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: midX - fitted.width / 2, y: midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}

nonisolated enum PolygonMath {
    /// Even-odd point-in-polygon test.
    static func contains(_ polygon: [CGPoint], point: CGPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y),
               point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Distance from `point` to the segment `a`–`b`.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return point.distance(to: a) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return point.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Ramer–Douglas–Peucker polyline simplification.
    static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = distance(from: points[i], toSegment: first, last)
            if d > maxDistance { maxDistance = d; index = i }
        }
        if maxDistance > epsilon {
            let left = simplify(Array(points[...index]), epsilon: epsilon)
            let right = simplify(Array(points[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }

    /// Resamples a polyline to points spaced evenly along its length.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return points }
        let interval = pathLength(points) / CGFloat(count - 1)
        guard interval > 0 else { return points }
        var result = [points[0]]
        var accumulated: CGFloat = 0
        var previous = points[0]
        var i = 1
        while i < points.count {
            let current = points[i]
            let d = previous.distance(to: current)
            if accumulated + d >= interval, d > 0 {
                let t = (interval - accumulated) / d
                let newPoint = CGPoint(x: previous.x + t * (current.x - previous.x),
                                       y: previous.y + t * (current.y - previous.y))
                result.append(newPoint)
                previous = newPoint
                accumulated = 0
            } else {
                accumulated += d
                previous = current
                i += 1
            }
        }
        if result.count < count, let last = points.last { result.append(last) }
        return result
    }
}
