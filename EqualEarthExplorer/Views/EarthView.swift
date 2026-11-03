import AppKit
import MetalKit
import Observation
import SwiftUI
import simd

/// SwiftUI wrapper around `EarthMTKView`, for both the map and the side-panel globe.
struct EarthView: NSViewRepresentable {
    let mode: ViewMode
    let state: ViewState
    let imagery: ImageryStore

    func makeNSView(context: Context) -> EarthMTKView {
        EarthMTKView(mode: mode, state: state, imagery: imagery)
    }

    func updateNSView(_ view: EarthMTKView, context: Context) {
        view.needsDisplay = true
    }
}

/// Metal view that redraws on demand and turns mouse and trackpad input into rotations.
final class EarthMTKView: MTKView {
    let mode: ViewMode
    private let state: ViewState
    private let imagery: ImageryStore
    private let metal = MetalContext.shared

    private enum Drag {
        /// Grab-and-drag: `start` is the view-frame vector under the pointer at mouse-down.
        case grab(start: SIMD3<Double>, orientation: simd_quatd)
        /// Option-drag: roll about the map centre.
        case roll(startX: Double, orientation: simd_quatd)
    }
    private var drag: Drag?

    init(mode: ViewMode, state: ViewState, imagery: ImageryStore) {
        self.mode = mode
        self.state = state
        self.imagery = imagery
        super.init(frame: .zero, device: MetalContext.shared.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        let bg = MetalContext.backgroundColor
        clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        observeState()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let pointScale = Float(window?.backingScaleFactor ?? 2)
        metal.draw(in: self, mode: mode, state: state, imagery: imagery, pointScale: pointScale)
    }

    /// Redraws whenever anything the picture depends on changes.
    private func observeState() {
        withObservationTracking {
            _ = state.orientation
            _ = state.showGraticule
            _ = state.showCoastlines
            _ = state.showBorders
            _ = state.showTissot
            _ = state.showOutline
            _ = state.showRivers
            _ = state.showStates
            _ = state.baseMap
            _ = imagery.texture
            _ = metal.coastlines
            _ = metal.borders
            _ = metal.rivers
            _ = metal.states
            _ = metal.politicalTexture
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.needsDisplay = true
                self?.observeState()
            }
        }
    }

    // MARK: - Coordinates

    private var layout: ViewLayout { ViewLayout(size: bounds.size, mode: mode) }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// View-frame unit vector under a point, or `nil` outside the map or globe.
    private func viewVector(at point: CGPoint) -> SIMD3<Double>? {
        let p = layout.projection(fromView: point)
        switch mode {
        case .map:
            guard let lp = EqualEarth.inverse(p) else { return nil }
            return Sphere.vector(longitude: lp.longitude, latitude: lp.latitude)
        case .globe:
            let r2 = simd_length_squared(p)
            guard r2 <= 1 else { return nil }
            return SIMD3((1 - r2).squareRoot(), p.x, p.y)
        }
    }

    /// Like `viewVector`, but points outside are moved onto the outline or the limb.
    private func clampedViewVector(at point: CGPoint) -> SIMD3<Double> {
        let p = layout.projection(fromView: point)
        switch mode {
        case .map:
            let lp = EqualEarth.inverseClamped(p)
            return Sphere.vector(longitude: lp.longitude, latitude: lp.latitude)
        case .globe:
            let r = simd_length(p)
            let q = r > 1 ? p / r : p
            return SIMD3(max(0, 1 - simd_length_squared(q)).squareRoot(), q.x, q.y)
        }
    }

    /// Rotation from geographic coordinates into this view's frame.
    private func geoToView(_ r: simd_quatd) -> simd_quatd {
        mode == .map ? r : Orientation.northUp(r)
    }

    // MARK: - Mouse and trackpad

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        state.cursor = nil
    }

    private func updateCursor(at point: CGPoint) {
        guard let v = viewVector(at: point) else {
            state.cursor = nil
            return
        }
        let c = Sphere.coordinates(geoToView(state.orientation).inverse.act(v))
        state.cursor = GeoPoint(longitude: c.longitude, latitude: c.latitude)
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        if event.modifierFlags.contains(.option) {
            drag = .roll(startX: Double(point.x), orientation: state.orientation)
        } else if let v = viewVector(at: point) {
            drag = .grab(start: v, orientation: state.orientation)
            NSCursor.closedHand.push()
        } else {
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        switch drag {
        case .grab(let start, let r0):
            let q = Orientation.shortestArc(from: start, to: clampedViewVector(at: point))
            switch mode {
            case .map:
                // The grabbed point moves from `start` to the pointer: R = q · R0.
                state.setOrientation(q * r0)
            case .globe:
                // Turn the north-up globe, keep the map's roll.
                let roll = Orientation.roll(of: r0)
                let g = Orientation.northUp(q * Orientation.northUp(r0))
                state.setOrientation(simd_quatd(angle: roll, axis: SIMD3(1, 0, 0)) * g)
            }
            updateCursor(at: point)
        case .roll(let startX, let r0):
            // Dragging to the right turns the map clockwise.
            let angle = -(Double(point.x) - startX) * 0.01
            state.setOrientation(simd_quatd(angle: angle, axis: SIMD3(1, 0, 0)) * r0)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .grab = drag { NSCursor.pop() }
        drag = nil
    }

    /// Two-finger trackpad rotation: roll about the map centre (counter-clockwise positive).
    override func rotate(with event: NSEvent) {
        let angle = Double(event.rotation) * .pi / 180
        state.setOrientation(simd_quatd(angle: angle, axis: SIMD3(1, 0, 0)) * state.orientation)
    }

    /// Scrolling moves the globe like a drag that starts in the centre of the view.
    override func scrollWheel(with event: NSEvent) {
        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas {
            dx *= 8
            dy *= 8
        }
        guard dx != 0 || dy != 0 else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let target = CGPoint(x: centre.x + dx, y: centre.y - dy)
        let q = Orientation.shortestArc(from: clampedViewVector(at: centre), to: clampedViewVector(at: target))
        let r = state.orientation
        switch mode {
        case .map:
            state.setOrientation(q * r)
        case .globe:
            let g = Orientation.northUp(q * Orientation.northUp(r))
            state.setOrientation(simd_quatd(angle: Orientation.roll(of: r), axis: SIMD3(1, 0, 0)) * g)
        }
    }
}
