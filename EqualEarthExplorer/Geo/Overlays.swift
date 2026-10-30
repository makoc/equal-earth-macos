import Foundation
import simd

/// Line work for the vector overlays. A segment list stores consecutive pairs (a, b) of
/// points; `SIMD3<Float>` has a 16-byte stride, matching `float3` in `Shaders.metal`.
struct SegmentList: Sendable {
    /// In which coordinate system the points are given.
    enum Space: Int, Sendable {
        /// Geographic unit vectors; they move with the globe.
        case geographic = 0
        /// Map-frame unit vectors; they stay fixed relative to the map.
        case mapFrame = 1
        /// Equal Earth projection-plane coordinates (x, y, 0); map view only.
        case plane = 2
    }

    var space: Space
    var points: [SIMD3<Float>] = []

    var segmentCount: Int { points.count / 2 }

    /// Adds a polyline of unit vectors, subdividing along great circles so that no
    /// segment is longer than `maxStep` radians. The vertex shader drops segments that
    /// cross the map's cut line; short segments keep that gap invisible.
    mutating func addPolyline(_ line: [SIMD3<Double>], maxStep: Double = .pi / 360) {
        guard line.count > 1 else { return }
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let n = max(1, Int(ceil(Sphere.angle(a, b) / maxStep)))
            var prev = a
            for k in 1...n {
                let next = k == n ? b : Sphere.slerp(a, b, Double(k) / Double(n))
                points.append(SIMD3<Float>(prev))
                points.append(SIMD3<Float>(next))
                prev = next
            }
        }
    }

    mutating func addPlanePolyline(_ line: [SIMD2<Double>]) {
        guard line.count > 1 else { return }
        for i in 1..<line.count {
            points.append(SIMD3<Float>(Float(line[i - 1].x), Float(line[i - 1].y), 0))
            points.append(SIMD3<Float>(Float(line[i].x), Float(line[i].y), 0))
        }
    }

    /// A zero-length segment, drawn as a round dot.
    mutating func addDot(_ v: SIMD3<Double>) {
        points.append(SIMD3<Float>(v))
        points.append(SIMD3<Float>(v))
    }
}

enum Overlays {
    static let degree = Double.pi / 180

    /// Meridians and parallels every `step` degrees.
    static func graticule(step: Double = 15) -> SegmentList {
        var list = SegmentList(space: .geographic)
        var lon = -180.0
        while lon < 180 {
            let line = stride(from: -90.0, through: 90.0, by: 1).map {
                Sphere.vector(longitude: lon * degree, latitude: $0 * degree)
            }
            list.addPolyline(line)
            lon += step
        }
        var lat = -90.0 + step
        while lat < 90 - 1e-9 {
            let line = stride(from: -180.0, through: 180.0, by: 1).map {
                Sphere.vector(longitude: $0 * degree, latitude: lat * degree)
            }
            list.addPolyline(line)
            lat += step
        }
        return list
    }

    /// Centres of the Tissot indicatrices: a `step`-degree grid plus both poles.
    static func tissotCentres(step: Double = 30) -> [SIMD3<Double>] {
        var centres: [SIMD3<Double>] = [SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        for lat in stride(from: -90.0 + step, through: 90.0 - step, by: step) {
            for lon in stride(from: -180.0, to: 180.0, by: step) {
                centres.append(Sphere.vector(longitude: lon * degree, latitude: lat * degree))
            }
        }
        return centres
    }

    /// Outlines of small circles of equal area on the sphere (radius in radians).
    static func tissotOutlines(radius: Double, step: Double = 30) -> SegmentList {
        var list = SegmentList(space: .geographic)
        for c in tissotCentres(step: step) {
            // Two unit vectors orthogonal to the centre span the circle's plane.
            var e1 = simd_cross(c, SIMD3(0, 0, 1))
            if simd_length(e1) < 1e-6 { e1 = SIMD3(1, 0, 0) }
            e1 = simd_normalize(e1)
            let e2 = simd_cross(c, e1)
            let ring = (0...72).map { k -> SIMD3<Double> in
                let t = Double(k) / 72 * 2 * .pi
                return c * cos(radius) + (e1 * cos(t) + e2 * sin(t)) * sin(radius)
            }
            list.addPolyline(ring)
        }
        return list
    }

    /// Outline of the Equal Earth map in the projection plane.
    static func mapOutline() -> SegmentList {
        var list = SegmentList(space: .plane)
        let east = stride(from: -90.0, through: 90.0, by: 0.5).map {
            EqualEarth.forward(longitude: .pi, latitude: $0 * degree)
        }
        let west = east.map { SIMD2(-$0.x, $0.y) }
        list.addPlanePolyline(east)
        list.addPlanePolyline(west)
        // Flat pole lines.
        list.addPlanePolyline([west.last!, east.last!])
        list.addPlanePolyline([west.first!, east.first!])
        return list
    }

    /// The map's cut line (map-frame antimeridian), the map-frame equator and the central
    /// meridian, all in the map frame. Shown on the globe to explain how the map is cut.
    static func mapFrameLines() -> (cut: SegmentList, frame: SegmentList) {
        var cut = SegmentList(space: .mapFrame)
        cut.addPolyline(stride(from: -90.0, through: 90.0, by: 1).map {
            Sphere.vector(longitude: .pi, latitude: $0 * degree)
        })
        var frame = SegmentList(space: .mapFrame)
        frame.addPolyline(stride(from: -180.0, through: 180.0, by: 1).map {
            Sphere.vector(longitude: $0 * degree, latitude: 0)
        })
        frame.addPolyline(stride(from: -90.0, through: 90.0, by: 1).map {
            Sphere.vector(longitude: 0, latitude: $0 * degree)
        })
        return (cut, frame)
    }

    static func northPole() -> SegmentList {
        var list = SegmentList(space: .geographic)
        list.addDot(SIMD3(0, 0, 1))
        return list
    }

    static func southPole() -> SegmentList {
        var list = SegmentList(space: .geographic)
        list.addDot(SIMD3(0, 0, -1))
        return list
    }
}
