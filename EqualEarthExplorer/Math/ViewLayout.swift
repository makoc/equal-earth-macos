import CoreGraphics

/// Which picture a Metal view draws.
enum ViewMode: Int {
    /// Equal Earth map of the rotated globe.
    case map = 0
    /// Orthographic globe, used in the side panel.
    case globe = 1
}

/// Fits the map (or the globe) into a view and converts between view coordinates and
/// projection-plane coordinates. View coordinates have their origin in the lower-left
/// corner with y pointing up (AppKit convention). The same formula is used in pixels
/// for the GPU and in points for mouse input, so both always agree.
struct ViewLayout {
    var size: CGSize
    var mode: ViewMode

    /// Length of one projection unit (map) or of the globe radius (globe), in view units.
    var scale: Double {
        let w = Double(size.width), h = Double(size.height)
        switch mode {
        case .map: return min(w / (2 * EqualEarth.xMax), h / (2 * EqualEarth.yMax)) * 0.94
        case .globe: return min(w, h) / 2 * 0.92
        }
    }

    func projection(fromView p: CGPoint) -> SIMD2<Double> {
        let s = scale
        return SIMD2((Double(p.x) - Double(size.width) / 2) / s,
                     (Double(p.y) - Double(size.height) / 2) / s)
    }
}
