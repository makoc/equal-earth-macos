import Foundation
import Observation
import simd

struct GeoPoint: Equatable {
    var longitude: Double   // radians
    var latitude: Double    // radians
}

/// Shared state of the map and the side-panel globe.
@MainActor
@Observable
final class ViewState {
    /// Rotation from geographic coordinates into the map frame (see `Orientation`).
    private(set) var orientation: simd_quatd = Orientation.identity

    var showGraticule = true
    var showCoastlines = true
    var showBorders = true
    var showTissot = false
    var showOutline = true

    /// Geographic position under the mouse pointer, if it is over the map or the globe.
    var cursor: GeoPoint?

    @ObservationIgnored private var animation: Task<Void, Never>?

    var centre: GeoPoint {
        let c = Orientation.centre(of: orientation)
        return GeoPoint(longitude: c.longitude, latitude: c.latitude)
    }

    var roll: Double { Orientation.roll(of: orientation) }

    /// Where the geographic North Pole lies in map-frame coordinates.
    var northPoleOnMap: GeoPoint {
        let c = Sphere.coordinates(orientation.act(SIMD3(0, 0, 1)))
        return GeoPoint(longitude: c.longitude, latitude: c.latitude)
    }

    var isStandardOrientation: Bool {
        abs(abs(orientation.real) - 1) < 1e-9
    }

    /// Sets the orientation immediately (used while dragging) and stops any reset animation.
    func setOrientation(_ q: simd_quatd) {
        animation?.cancel()
        animation = nil
        orientation = simd_normalize(q)
    }

    /// Keeps the map centre and turns the globe so that north points up.
    func resetNorthUp() {
        animate(to: Orientation.northUp(orientation))
    }

    /// Back to the standard Equal Earth map: (0°, 0°) in the centre, north up.
    func resetToOrigin() {
        animate(to: Orientation.identity)
    }

    private func animate(to target: simd_quatd, duration: Double = 0.4) {
        animation?.cancel()
        let start = orientation
        let clock = ContinuousClock()
        let begin = clock.now
        animation = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = clock.now - begin
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let t01 = min(1, seconds / duration)
                let eased = t01 >= 1 ? 1 : 0.5 - 0.5 * cos(.pi * t01)
                self?.orientation = simd_normalize(simd_slerp(start, target, eased))
                if t01 >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }
}
