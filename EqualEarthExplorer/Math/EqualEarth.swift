import Foundation

/// Equal Earth projection (Šavrič, Patterson, Jenny, 2018), unit sphere, angles in radians.
///
/// The same formulas are implemented in `Shaders.metal` for the GPU (Graphics Processing Unit).
/// Keep both implementations in sync.
enum EqualEarth {
    static let a1 = 1.340264
    static let a2 = -0.081106
    static let a3 = 0.000893
    static let a4 = 0.003796
    /// √3 / 2
    static let m = 3.0.squareRoot() / 2.0

    /// Half width of the map: x at (λ = π, φ = 0). About 2.70663.
    static let xMax = forward(longitude: .pi, latitude: 0).x
    /// Half height of the map: y at φ = π / 2. About 1.31736.
    static let yMax = forward(longitude: 0, latitude: .pi / 2).y
    /// Parametric latitude θ at the poles.
    static let thetaMax = asin(m)

    static func forward(longitude lambda: Double, latitude phi: Double) -> SIMD2<Double> {
        let theta = asin(m * sin(phi))
        let t2 = theta * theta
        let t6 = t2 * t2 * t2
        let x = lambda * cos(theta) / (m * (a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)))
        let y = theta * (a1 + a2 * t2 + t6 * (a3 + a4 * t2))
        return SIMD2(x, y)
    }

    /// Inverse projection. Returns `nil` when the point lies outside the map outline.
    static func inverse(_ p: SIMD2<Double>) -> (longitude: Double, latitude: Double)? {
        guard abs(p.y) <= yMax else { return nil }
        let theta = solveTheta(p.y)
        let t2 = theta * theta
        let t6 = t2 * t2 * t2
        let lambda = m * p.x * (a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)) / cos(theta)
        guard abs(lambda) <= .pi else { return nil }
        let phi = asin(max(-1, min(1, sin(theta) / m)))
        return (lambda, phi)
    }

    /// Like `inverse`, but points outside the outline are moved onto the nearest edge
    /// (y is clamped first, then λ). Used to keep dragging smooth outside the map.
    static func inverseClamped(_ p: SIMD2<Double>) -> (longitude: Double, latitude: Double) {
        let y = max(-yMax, min(yMax, p.y))
        let theta = solveTheta(y)
        let t2 = theta * theta
        let t6 = t2 * t2 * t2
        let c = cos(theta)
        var lambda: Double
        if c < 1e-12 {
            lambda = 0
        } else {
            lambda = m * p.x * (a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)) / c
        }
        lambda = max(-.pi, min(.pi, lambda))
        let phi = asin(max(-1, min(1, sin(theta) / m)))
        return (lambda, phi)
    }

    /// Newton iteration for θ from y. Converges in 4 to 6 steps from θ = y / A1.
    private static func solveTheta(_ y: Double) -> Double {
        var theta = y / a1
        for _ in 0..<12 {
            let t2 = theta * theta
            let t6 = t2 * t2 * t2
            let f = theta * (a1 + a2 * t2 + t6 * (a3 + a4 * t2)) - y
            let fp = a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)
            let delta = f / fp
            theta -= delta
            if abs(delta) < 1e-12 { break }
        }
        return max(-thetaMax, min(thetaMax, theta))
    }
}
