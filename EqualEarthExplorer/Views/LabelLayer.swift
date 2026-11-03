import AppKit
import SwiftUI
import simd

/// Country, capital and city names on the map. Labels are placed in priority order and
/// skipped where they would overlap a label already placed or cross the map outline.
struct LabelLayer: View {
    let state: ViewState
    let labels: [MapLabel]
    @State private var metrics = LabelMetrics()

    var body: some View {
        // Read here so that SwiftUI redraws the canvas when they change.
        let orientation = state.orientation
        let political = state.baseMap == .political
        Canvas { context, size in
            draw(in: &context, size: size, orientation: orientation, political: political)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, orientation: simd_quatd, political: Bool) {
        let layout = ViewLayout(size: size, mode: .map)
        let s = layout.scale
        let bounds = CGRect(origin: .zero, size: size)
        let textColor: Color = political ? Color(white: 0.12) : .white
        let countryColor: Color = political ? Color(white: 0.3) : Color(white: 0.92)
        // A halo keeps the text readable on any background.
        context.addFilter(.shadow(color: political ? .white.opacity(0.9) : .black.opacity(0.9), radius: 1.2))

        func viewPoint(_ v: SIMD3<Double>) -> CGPoint {
            let c = Sphere.coordinates(orientation.act(v))
            let p = EqualEarth.forward(longitude: c.longitude, latitude: c.latitude)
            return CGPoint(x: size.width / 2 + p.x * s, y: size.height / 2 - p.y * s)
        }
        func insideMap(_ p: CGPoint) -> Bool {
            EqualEarth.inverse(SIMD2((p.x - size.width / 2) / s, (size.height / 2 - p.y) / s)) != nil
        }

        var placed: [CGRect] = []
        for label in labels {
            let anchor = viewPoint(label.position)
            let text = metrics.size(of: label)
            let dotRadius: CGFloat = label.kind == .capital ? 3 : 2.2
            let rect: CGRect = switch label.kind {
            case .country:
                CGRect(x: anchor.x - text.width / 2, y: anchor.y - text.height / 2, width: text.width, height: text.height)
            case .capital, .city:
                CGRect(x: anchor.x + dotRadius + 3, y: anchor.y - text.height / 2, width: text.width, height: text.height)
            }
            let footprint = (label.kind == .country ? rect : rect.union(CGRect(x: anchor.x - dotRadius, y: anchor.y - dotRadius,
                                                                                width: 2 * dotRadius, height: 2 * dotRadius)))
                .insetBy(dx: -2, dy: -1)
            guard bounds.contains(footprint),
                  [CGPoint(x: footprint.minX, y: footprint.minY), CGPoint(x: footprint.maxX, y: footprint.minY),
                   CGPoint(x: footprint.minX, y: footprint.maxY), CGPoint(x: footprint.maxX, y: footprint.maxY)].allSatisfy(insideMap),
                  !placed.contains(where: { $0.intersects(footprint) }) else { continue }
            placed.append(footprint)

            if label.kind != .country {
                let dot = Path(ellipseIn: CGRect(x: anchor.x - dotRadius, y: anchor.y - dotRadius,
                                                 width: 2 * dotRadius, height: 2 * dotRadius))
                context.fill(dot, with: .color(political ? Color(white: 0.15) : .white))
                if label.kind == .capital {
                    context.stroke(dot, with: .color(political ? .white : .black), lineWidth: 1)
                }
            }
            let style = LabelMetrics.style(label.kind)
            let drawn = Text(label.text)
                .font(.system(size: style.size, weight: style.weight))
                .tracking(style.tracking)
                .foregroundStyle(label.kind == .country ? countryColor : textColor)
            context.draw(drawn, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }
}

/// Text sizes of the labels, measured once.
@MainActor
final class LabelMetrics {
    struct Style {
        var size: CGFloat
        var weight: Font.Weight
        var nsWeight: NSFont.Weight
        var tracking: CGFloat
    }

    static func style(_ kind: MapLabel.Kind) -> Style {
        switch kind {
        case .country: Style(size: 10, weight: .semibold, nsWeight: .semibold, tracking: 0.8)
        case .capital: Style(size: 11, weight: .medium, nsWeight: .medium, tracking: 0)
        case .city: Style(size: 10.5, weight: .regular, nsWeight: .regular, tracking: 0)
        }
    }

    private var cache: [String: CGSize] = [:]

    func size(of label: MapLabel) -> CGSize {
        let key = "\(label.kind)|\(label.text)"
        if let size = cache[key] { return size }
        let style = Self.style(label.kind)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: style.size, weight: style.nsWeight),
            .kern: style.tracking,
        ]
        let size = (label.text as NSString).size(withAttributes: attributes)
        cache[key] = size
        return size
    }
}
