import Foundation
import simd

/// Conventions used throughout the app:
/// - Unit vectors: x → (0° N, 0° E), y → (0° N, 90° E), z → North Pole.
/// - An orientation `R` maps geographic vectors into the *map frame*. Map-frame longitude
///   and latitude are fed into the Equal Earth formulas. The map centre is the map-frame
///   vector +x, map-frame "up" at the centre is +z, "right" (east) is +y.
enum Sphere {
    static func vector(longitude: Double, latitude: Double) -> SIMD3<Double> {
        let c = cos(latitude)
        return SIMD3(c * cos(longitude), c * sin(longitude), sin(latitude))
    }

    static func coordinates(_ v: SIMD3<Double>) -> (longitude: Double, latitude: Double) {
        let n = simd_normalize(v)
        return (atan2(n.y, n.x), asin(max(-1, min(1, n.z))))
    }

    /// Spherical linear interpolation between two unit vectors.
    static func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let d = max(-1, min(1, simd_dot(a, b)))
        let omega = acos(d)
        if omega < 1e-9 { return a }
        let s = sin(omega)
        return simd_normalize(a * (sin((1 - t) * omega) / s) + b * (sin(t * omega) / s))
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }
}

enum Orientation {
    static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    /// R = Rx(roll) · Ry(φc) · Rz(−λc): brings (λc, φc) to the map centre, then rolls.
    static func make(centreLongitude lambda: Double, centreLatitude phi: Double, roll: Double = 0) -> simd_quatd {
        let qz = simd_quatd(angle: -lambda, axis: SIMD3(0, 0, 1))
        let qy = simd_quatd(angle: phi, axis: SIMD3(0, 1, 0))
        let qx = simd_quatd(angle: roll, axis: SIMD3(1, 0, 0))
        return simd_normalize(qx * qy * qz)
    }

    /// Geographic coordinates of the point shown in the map centre.
    static func centre(of r: simd_quatd) -> (longitude: Double, latitude: Double) {
        Sphere.coordinates(r.inverse.act(SIMD3(1, 0, 0)))
    }

    /// Roll angle γ: how far geographic north at the map centre is turned away from "up"
    /// (counter-clockwise positive). Undefined (returns 0) when a pole is in the centre.
    static func roll(of r: simd_quatd) -> Double {
        let n = r.act(SIMD3(0, 0, 1))
        if n.y * n.y + n.z * n.z < 1e-18 { return 0 }
        return atan2(-n.y, n.z)
    }

    /// Same map centre, roll removed: north points straight up at the centre.
    static func northUp(_ r: simd_quatd) -> simd_quatd {
        simd_normalize(simd_quatd(angle: -roll(of: r), axis: SIMD3(1, 0, 0)) * r)
    }

    /// Shortest-arc rotation that takes unit vector `a` to unit vector `b`.
    static func shortestArc(from a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_quatd {
        let a = simd_normalize(a)
        let b = simd_normalize(b)
        let d = simd_dot(a, b)
        if d > 1 - 1e-15 { return identity }
        if d < -1 + 1e-12 {
            // Opposite vectors: rotate by π about any axis orthogonal to a.
            var axis = simd_cross(a, SIMD3(1, 0, 0))
            if simd_length(axis) < 1e-6 { axis = simd_cross(a, SIMD3(0, 1, 0)) }
            return simd_quatd(angle: .pi, axis: simd_normalize(axis))
        }
        return simd_quatd(from: a, to: b)
    }

    /// Rotation matrix with the quaternion in the upper-left 3 × 3 block, for the shaders.
    static func matrix(_ q: simd_quatd) -> simd_float4x4 {
        let m = simd_double3x3(q)
        func col(_ c: SIMD3<Double>) -> SIMD4<Float> { SIMD4(Float(c.x), Float(c.y), Float(c.z), 0) }
        return simd_float4x4(col(m.columns.0), col(m.columns.1), col(m.columns.2), SIMD4(0, 0, 0, 1))
    }
}
