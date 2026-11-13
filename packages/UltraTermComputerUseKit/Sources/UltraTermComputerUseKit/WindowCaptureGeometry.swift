import CoreGraphics

/// Geometry rules for window screenshots: a hardware capture holds only the on-screen part, so a window that is off-screen or spans displays needs a whole-window capture,
/// and the result's pixel size must keep the window's proportions; otherwise return no image so coordinates are never computed from a cropped one.
enum WindowCaptureGeometry {
    static func isValid(_ bounds: CGRect) -> Bool {
        !bounds.isInfinite && !bounds.isNull
            && [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite)
            && bounds.size.width > 0 && bounds.size.height > 0
    }

    static func matchesFullWindow(pixelSize: CGSize, bounds: CGRect) -> Bool {
        guard
            isValid(bounds), pixelSize.width.isFinite, pixelSize.height.isFinite,
            pixelSize.width > 0, pixelSize.height > 0 else { return false }
        // Proportional encoding rounds to whole pixels; a cropped image must not be stretched to the full window.
        let scale = min(pixelSize.width / bounds.width, pixelSize.height / bounds.height)
        return abs(pixelSize.width - bounds.width * scale) <= 2
            && abs(pixelSize.height - bounds.height * scale) <= 2
    }

    /// Prefer the hardware capture within one display; use the whole-window capture when the window is off-screen, spans displays or the coverage looks wrong.
    static func capture(
        bounds: CGRect, displayBounds: [CGRect],
        hardware: () -> CGImage?, fullWindow: () -> CGImage?
    ) -> CGImage? {
        guard isValid(bounds) else { return nil }
        if
            displayBounds.contains(where: { $0.contains(bounds) }),
            let image = hardware(), matchesFullWindow(pixelSize: size(of: image), bounds: bounds) {
            return image
        }
        guard
            let image = fullWindow(),
            matchesFullWindow(pixelSize: size(of: image), bounds: bounds) else { return nil }
        return image
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
