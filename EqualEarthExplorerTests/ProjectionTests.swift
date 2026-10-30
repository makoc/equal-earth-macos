import Foundation
import Testing
@testable import EqualEarthExplorer

struct ProjectionTests {
    private let degree = Double.pi / 180

    @Test func mapExtent() {
        #expect(abs(EqualEarth.xMax - 2.7066299836960748) < 1e-12)
        #expect(abs(EqualEarth.yMax - 1.3173627591574133) < 1e-12)
    }

    struct ReferenceCase: Sendable {
        let lon: Double, lat: Double, x: Double, y: Double
    }

    /// Values from an independent Python implementation of the published formulas.
    @Test(arguments: [
        ReferenceCase(lon: 10, lat: 50, x: 0.12403502783330472, y: 0.941540234660433),
        ReferenceCase(lon: -120, lat: -30, x: -1.6878011172181766, y: -0.592935119848017),
    ])
    func referenceValues(_ c: ReferenceCase) {
        let p = EqualEarth.forward(longitude: c.lon * degree, latitude: c.lat * degree)
        #expect(abs(p.x - c.x) < 1e-12)
        #expect(abs(p.y - c.y) < 1e-12)
    }

    @Test func roundTrip() throws {
        for lat in stride(from: -89.5, through: 89.5, by: 2.5) {
            for lon in stride(from: -179.5, through: 179.5, by: 5) {
                let p = EqualEarth.forward(longitude: lon * degree, latitude: lat * degree)
                let back = try #require(EqualEarth.inverse(p))
                #expect(abs(back.longitude - lon * degree) < 1e-9)
                #expect(abs(back.latitude - lat * degree) < 1e-9)
            }
        }
    }

    @Test func outsideOutline() {
        #expect(EqualEarth.inverse(SIMD2(0, EqualEarth.yMax + 0.01)) == nil)
        #expect(EqualEarth.inverse(SIMD2(EqualEarth.xMax + 0.01, 0)) == nil)
        // Inside the bounding box but beyond the curved edge.
        #expect(EqualEarth.inverse(SIMD2(EqualEarth.xMax * 0.99, EqualEarth.yMax * 0.9)) == nil)
    }

    @Test func clampedInverseStaysOnEdge() {
        let c = EqualEarth.inverseClamped(SIMD2(10, 0))
        #expect(abs(c.longitude - .pi) < 1e-12)
        #expect(abs(c.latitude) < 1e-12)
        let top = EqualEarth.inverseClamped(SIMD2(0, 5))
        #expect(abs(top.latitude - .pi / 2) < 1e-9)
    }
}
