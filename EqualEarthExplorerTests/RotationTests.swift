import Foundation
import simd
import Testing
@testable import EqualEarthExplorer

struct RotationTests {
    private let degree = Double.pi / 180

    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-12) -> Bool {
        simd_length(a - b) < tolerance
    }

    @Test func makeBringsCentreToMapCentre() {
        let r = Orientation.make(centreLongitude: 40 * degree, centreLatitude: -25 * degree, roll: 30 * degree)
        let centre = Sphere.vector(longitude: 40 * degree, latitude: -25 * degree)
        #expect(close(r.act(centre), SIMD3(1, 0, 0)))
        let c = Orientation.centre(of: r)
        #expect(abs(c.longitude - 40 * degree) < 1e-12)
        #expect(abs(c.latitude + 25 * degree) < 1e-12)
        #expect(abs(Orientation.roll(of: r) - 30 * degree) < 1e-12)
    }

    @Test func northUpKeepsCentreAndRemovesRoll() {
        let r = Orientation.make(centreLongitude: -70 * degree, centreLatitude: 52 * degree, roll: -110 * degree)
        let n = Orientation.northUp(r)
        #expect(close(n.inverse.act(SIMD3(1, 0, 0)), r.inverse.act(SIMD3(1, 0, 0))))
        #expect(abs(Orientation.roll(of: n)) < 1e-12)
        // North is straight up: the pole lies on the map-frame central meridian (y′ = 0), above the centre.
        let pole = n.act(SIMD3(0, 0, 1))
        #expect(abs(pole.y) < 1e-12)
        #expect(pole.z > 0)
    }

    @Test func identityIsStandardMap() {
        let v = Sphere.vector(longitude: 12 * degree, latitude: 34 * degree)
        #expect(close(Orientation.identity.act(v), v))
        #expect(abs(Orientation.roll(of: Orientation.identity)) < 1e-15)
    }

    @Test func shortestArcMapsAToB() {
        let a = Sphere.vector(longitude: 10 * degree, latitude: 20 * degree)
        let b = Sphere.vector(longitude: -150 * degree, latitude: -40 * degree)
        #expect(close(Orientation.shortestArc(from: a, to: b).act(a), b))
        // Antipodal vectors.
        #expect(close(Orientation.shortestArc(from: a, to: -a).act(a), -a, 1e-9))
        #expect(close(Orientation.shortestArc(from: SIMD3(1, 0, 0), to: SIMD3(-1, 0, 0)).act(SIMD3(1, 0, 0)), SIMD3(-1, 0, 0), 1e-9))
    }

    /// Grab-and-drag: the grabbed geographic point ends up under the pointer.
    @Test func dragMovesGrabbedPoint() {
        let r0 = Orientation.make(centreLongitude: 30 * degree, centreLatitude: 10 * degree, roll: 5 * degree)
        let p0 = Sphere.vector(longitude: 20 * degree, latitude: 15 * degree)       // map frame
        let p1 = Sphere.vector(longitude: -60 * degree, latitude: -35 * degree)     // map frame
        let grabbed = r0.inverse.act(p0)                                             // geographic
        let r = Orientation.shortestArc(from: p0, to: p1) * r0
        #expect(close(r.act(grabbed), p1))
    }

    @Test func coordinatesRoundTrip() {
        for lat in stride(from: -80.0, through: 80.0, by: 20) {
            for lon in stride(from: -170.0, through: 170.0, by: 34) {
                let c = Sphere.coordinates(Sphere.vector(longitude: lon * degree, latitude: lat * degree))
                #expect(abs(c.longitude - lon * degree) < 1e-12)
                #expect(abs(c.latitude - lat * degree) < 1e-12)
            }
        }
    }

    @Test func densifiedSegmentsAreShort() {
        var list = SegmentList(space: .geographic)
        list.addPolyline([Sphere.vector(longitude: 0, latitude: 0), Sphere.vector(longitude: 90 * degree, latitude: 0)])
        #expect((180...181).contains(list.segmentCount))
        for i in stride(from: 0, to: list.points.count, by: 2) {
            let a = SIMD3<Double>(list.points[i]), b = SIMD3<Double>(list.points[i + 1])
            #expect(Sphere.angle(a, b) <= 0.5 * degree + 1e-6)
        }
    }
}
