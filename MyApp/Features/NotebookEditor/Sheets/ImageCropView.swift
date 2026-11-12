import SwiftUI

/// Rectangular crop with draggable corners. Produces a new image asset; the original
/// asset is left untouched so undo keeps working.
struct ImageCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Crop rect in normalised (0…1) image coordinates.
    @State private var crop = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var dragStartCrop: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let fitted = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 24, dy: 24).aspectFit(image.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                    let rect = CGRect(x: fitted.minX + crop.minX * fitted.width, y: fitted.minY + crop.minY * fitted.height,
                                      width: crop.width * fitted.width, height: crop.height * fitted.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        path.addRect(rect)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .contentShape(.rect)
                        .gesture(moveGesture(fitted: fitted))
                    ForEach(Corner.allCases, id: \.self) { corner in
                        Circle()
                            .fill(.white)
                            .frame(width: 26, height: 26)
                            .shadow(radius: 2)
                            .position(corner.point(in: rect))
                            .gesture(cornerGesture(corner, fitted: fitted))
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Crop Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crop") {
                        if let cropped = croppedImage() { onCrop(cropped) }
                        dismiss()
                    }
                }
            }
        }
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private func moveGesture(fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStartCrop ?? crop
                dragStartCrop = start
                var moved = start.offsetBy(dx: value.translation.width / fitted.width, dy: value.translation.height / fitted.height)
                moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                crop = moved
            }
            .onEnded { _ in dragStartCrop = nil }
    }

    private func cornerGesture(_ corner: Corner, fitted: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStartCrop ?? crop
                dragStartCrop = start
                let dx = value.translation.width / fitted.width
                let dy = value.translation.height / fitted.height
                var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
                switch corner {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }
                minX = min(max(minX, 0), maxX - 0.05); maxX = max(min(maxX, 1), minX + 0.05)
                minY = min(max(minY, 0), maxY - 0.05); maxY = max(min(maxY, 1), minY + 0.05)
                crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStartCrop = nil }
    }

    private func croppedImage() -> UIImage? {
        // Render with orientation applied, then crop in pixel space.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        guard let cg = upright.cgImage else { return nil }
        let rect = CGRect(x: crop.minX * CGFloat(cg.width), y: crop.minY * CGFloat(cg.height),
                          width: crop.width * CGFloat(cg.width), height: crop.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
