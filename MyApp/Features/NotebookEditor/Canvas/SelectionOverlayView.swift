import UIKit

/// Draws lasso paths, selection frames and transform handles above the ink.
/// Lives in page coordinates (same transform as the underlay).
final class SelectionOverlayView: UIView {
    enum Handle { case scale, rotate }

    private let lassoLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private let scaleHandle = CAShapeLayer()
    private let rotateHandle = CAShapeLayer()
    private let rotateStem = CAShapeLayer()
    private let previewView = UIImageView()

    private(set) var selectionFrame: CGRect?
    private(set) var selectionRotation: CGFloat = 0
    private var zoom: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.anchorPoint = .zero
        let accent = UIColor.tintColor.cgColor
        for shape in [lassoLayer, frameLayer, rotateStem] {
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = accent
        }
        lassoLayer.fillColor = UIColor.tintColor.withAlphaComponent(0.06).cgColor
        for handle in [scaleHandle, rotateHandle] {
            handle.fillColor = UIColor.white.cgColor
            handle.strokeColor = accent
        }
        previewView.layer.anchorPoint = .zero
        previewView.isHidden = true
        addSubview(previewView)
        [lassoLayer, frameLayer, rotateStem, scaleHandle, rotateHandle].forEach { layer.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(pageSize: CGSize) {
        let currentTransform = transform
        transform = .identity
        bounds = CGRect(origin: .zero, size: pageSize)
        layer.position = .zero
        transform = currentTransform
    }

    func setZoom(_ zoom: CGFloat) {
        self.zoom = max(zoom, 0.01)
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
        layer.position = .zero
        redrawSelection()
    }

    // MARK: Lasso

    func showLasso(_ points: [CGPoint]) {
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
        lassoLayer.lineWidth = 1.5 / zoom
        lassoLayer.lineDashPattern = [NSNumber(value: Double(6 / zoom)), NSNumber(value: Double(4 / zoom))]
        withoutAnimation { lassoLayer.path = path.cgPath }
    }

    func clearLasso() {
        withoutAnimation { lassoLayer.path = nil }
    }

    // MARK: Selection frame

    func showSelection(frame: CGRect, rotation: CGFloat = 0) {
        selectionFrame = frame
        selectionRotation = rotation
        redrawSelection()
    }

    func clearSelection() {
        selectionFrame = nil
        selectionRotation = 0
        withoutAnimation {
            frameLayer.path = nil
            scaleHandle.path = nil
            rotateHandle.path = nil
            rotateStem.path = nil
        }
    }

    private var handleRadius: CGFloat { 11 / zoom }
    private var stemLength: CGFloat { 34 / zoom }

    /// Handle positions in page coordinates.
    func handlePositions() -> (scale: CGPoint, rotate: CGPoint)? {
        guard let frame = selectionFrame else { return nil }
        let rotation = rotationTransform(for: frame)
        let scale = CGPoint(x: frame.maxX, y: frame.maxY).applying(rotation)
        let rotate = CGPoint(x: frame.midX, y: frame.minY - stemLength).applying(rotation)
        return (scale, rotate)
    }

    func handle(at point: CGPoint) -> Handle? {
        guard let positions = handlePositions() else { return nil }
        // Generous touch target (finger contact points are imprecise); about 70 pt across.
        let hitRadius = 34 / zoom
        // Inside the selection itself only touches close to a circle count as a handle,
        // so small selections can still be grabbed and moved.
        let insideFrame = selectionFrame.map { frame in
            frame.contains(point.applying(rotationTransform(for: frame).inverted()))
        } ?? false
        let limit = insideFrame ? 18 / zoom : hitRadius
        let scaleDistance = point.distance(to: positions.scale)
        let rotateDistance = point.distance(to: positions.rotate)
        if scaleDistance < limit, scaleDistance <= rotateDistance { return .scale }
        if rotateDistance < limit { return .rotate }
        if scaleDistance < limit { return .scale }
        return nil
    }

    func selectionContains(_ point: CGPoint) -> Bool {
        guard let frame = selectionFrame else { return false }
        let inverse = rotationTransform(for: frame).inverted()
        return frame.insetBy(dx: -16 / zoom, dy: -16 / zoom).contains(point.applying(inverse))
    }

    private func rotationTransform(for frame: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: selectionRotation)
            .translatedBy(x: -frame.midX, y: -frame.midY)
    }

    private func redrawSelection() {
        guard let frame = selectionFrame, let positions = handlePositions() else { return }
        let rotation = rotationTransform(for: frame)
        let framePath = UIBezierPath(rect: frame)
        framePath.apply(rotation)
        let stem = UIBezierPath()
        stem.move(to: CGPoint(x: frame.midX, y: frame.minY).applying(rotation))
        stem.addLine(to: positions.rotate)
        withoutAnimation {
            frameLayer.lineWidth = 1.2 / zoom
            frameLayer.lineDashPattern = [NSNumber(value: Double(5 / zoom)), NSNumber(value: Double(3 / zoom))]
            frameLayer.path = framePath.cgPath
            rotateStem.lineWidth = 1.2 / zoom
            rotateStem.path = stem.cgPath
            for (layer, center) in [(scaleHandle, positions.scale), (rotateHandle, positions.rotate)] {
                layer.lineWidth = 1.5 / zoom
                layer.path = UIBezierPath(ovalIn: CGRect(x: center.x - handleRadius, y: center.y - handleRadius,
                                                         width: handleRadius * 2, height: handleRadius * 2)).cgPath
            }
        }
    }

    // MARK: Live transform preview for ink

    /// Shows a raster of the selected ink so dragging never re-renders the whole drawing.
    func beginPreview(image: UIImage, frame: CGRect) {
        previewView.image = image
        previewView.bounds = CGRect(origin: .zero, size: frame.size)
        previewView.layer.position = .zero
        previewView.transform = CGAffineTransform(translationX: frame.minX, y: frame.minY)
        previewView.isHidden = false
        previewOrigin = frame.origin
    }

    private var previewOrigin: CGPoint = .zero

    func updatePreview(transform: CGAffineTransform) {
        previewView.transform = CGAffineTransform(translationX: previewOrigin.x, y: previewOrigin.y).concatenating(transform)
    }

    func endPreview() {
        previewView.isHidden = true
        previewView.image = nil
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
