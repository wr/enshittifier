import SwiftUI
import AppKit

/// Renders the same SVG glyph the patcher draws into fonts (see
/// `SVG_POOP_PATH` in `engine/enshittifier.py`), as a tintable SwiftUI Image.
///
/// We load via NSImage(data:) so the SVG bytes can live inline in code
/// (no Resources bundle plumbing). isTemplate=true lets SwiftUI's
/// `foregroundStyle` tint the rendered glyph.
struct PoopGlyph: View {
    var size: CGFloat = 16
    var tint: Color = .primary

    var body: some View {
        if let img = Self.cachedImage {
            Image(nsImage: img)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(Self.viewBoxWidth / Self.viewBoxHeight, contentMode: .fit)
                .frame(width: size, height: size * Self.viewBoxHeight / Self.viewBoxWidth)
                .foregroundStyle(tint)
        } else {
            // Fallback: emoji.
            Text("💩")
                .font(.system(size: size))
        }
    }

    // MARK: - Cached NSImage

    private static let viewBoxWidth: CGFloat = 75
    private static let viewBoxHeight: CGFloat = 71

    private static let svgData: String = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 75 71" fill-rule="evenodd">
    <path d="M56.7124 34.0845C57.0124 34.9845 63.1124 32.9845 65.5124 39.9845C67.5124 46.0845 63.4124 48.8845 63.8124 49.6845C64.3124 50.6845 74.6124 52.6845 74.8124 59.1845C75.0124 68.1845 62.6124 70.2845 59.6124 70.2845C42.1124 70.4845 31.9124 67.5845 23.0124 67.7845C19.4124 67.8845 13.0124 70.7845 8.71243 70.2845C5.01243 69.7845 -0.887567 66.7845 0.112433 59.0845C1.61243 47.2845 11.0124 49.7845 11.1124 49.0845C11.2124 48.0845 7.71243 46.6845 9.11243 40.4845C10.7124 33.3845 16.8124 35.1845 17.3124 33.2845C17.5124 32.5845 15.7124 27.8845 16.8124 23.9845C18.0124 19.5845 25.8124 17.2845 26.1124 16.5845C26.6124 15.5845 24.7124 14.7845 24.7124 13.6845C24.8124 9.48454 28.8124 7.68454 28.9124 4.88454C28.9124 3.48454 27.8124 1.48454 28.5124 0.384539C30.0124 -1.81546 42.1124 5.98454 45.2124 9.58454C49.9124 15.1845 48.9124 17.7845 48.1124 21.5845C48.1124 21.5845 55.3124 22.3845 57.2124 25.8845C59.2124 29.4845 56.5124 33.3845 56.7124 34.0845Z M24.7124 28.2845C20.1124 28.2845 16.4124 32.9845 16.4124 38.8845C16.4124 44.7845 20.1124 49.4845 24.7124 49.4845C29.3124 49.4845 33.0124 44.7845 33.0124 38.8845C33.0124 32.9845 29.3124 28.2845 24.7124 28.2845Z M48.9124 28.2845C44.3124 28.2845 40.6124 32.9845 40.6124 38.8845C40.6124 44.7845 44.3124 49.4845 48.9124 49.4845C53.5124 49.4845 57.2124 44.7845 57.2124 38.8845C57.2124 32.9845 53.5124 28.2845 48.9124 28.2845Z M22.7124 53.4845C22.7124 53.4845 26.0124 61.6845 36.5124 61.6845C46.2124 61.6845 50.3124 53.5845 50.3124 53.5845L22.7124 53.4845Z M24.7124 33.3845C22.4124 33.3845 20.6124 35.9845 20.6124 39.1845C20.6124 42.3845 22.4124 44.9845 24.7124 44.9845C27.0124 44.9845 28.8124 42.3845 28.8124 39.1845C28.8124 35.9845 27.0124 33.3845 24.7124 33.3845Z M49.0124 33.3845C46.7124 33.3845 44.9124 35.9845 44.9124 39.1845C44.9124 42.3845 46.7124 44.9845 49.0124 44.9845C51.3124 44.9845 53.1124 42.3845 53.1124 39.1845C53.1124 35.9845 51.2124 33.3845 49.0124 33.3845Z"/>
    </svg>
    """

    private static let cachedImage: NSImage? = {
        guard let data = svgData.data(using: .utf8),
              let img = NSImage(data: data) else { return nil }
        img.isTemplate = true
        return img
    }()
}

/// Standardised macOS selection indicator: empty circle when off; a
/// vibrant blue circle with white check (or minus for partial), white
/// outer border, and soft drop shadow — matches the iOS-style
/// affordance the user requested.
struct SelectionCircle: View {
    let state: SelectionState
    let onTap: () -> Void
    var size: CGFloat = 24

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .off:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
                .frame(width: size, height: size)
        case .partial:
            filledCircle(symbol: "minus")
        case .on:
            filledCircle(symbol: "checkmark")
        }
    }

    private func filledCircle(symbol: String) -> some View {
        ZStack {
            Circle().fill(Self.fillBlue)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
    }

    private static let fillBlue = Color(red: 0.0, green: 0.47, blue: 1.0)
}
