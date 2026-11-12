import SwiftUI

/// Lazily rendered page thumbnail. Rendering happens off the main thread through
/// `ThumbnailService`; the `.task(id:)` key changes whenever the page content changes.
struct PageThumbnailView: View {
    let page: Page
    var width: CGFloat = 160
    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        let snapshot = page.renderSnapshot(store: env.store)
        let pixelWidth = (width * displayScale).rounded()
        let aspect = snapshot.size.width / max(snapshot.size.height, 1)
        ZStack {
            Rectangle().fill(Color(hex: snapshot.style.backgroundColorHex))
            if let image = image ?? env.thumbnails.cachedThumbnail(for: snapshot, pixelWidth: pixelWidth) {
                Image(uiImage: image).resizable().interpolation(.medium)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(width: width)
        .clipShape(.rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Colors.hairline))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .task(id: snapshot) {
            image = await env.thumbnails.thumbnail(for: snapshot, pixelWidth: pixelWidth)
        }
        .accessibilityHidden(true)
    }
}
