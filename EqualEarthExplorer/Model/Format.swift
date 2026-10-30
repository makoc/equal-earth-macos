import Foundation

/// Text for angles and coordinates (degrees, two decimals).
enum Format {
    private static func degrees(_ radians: Double, digits: Int = 2) -> String {
        (radians * 180 / .pi).formatted(.number.precision(.fractionLength(digits)))
    }

    static func latitude(_ radians: Double) -> String {
        degrees(abs(radians)) + "° " + (radians >= 0 ? "N" : "S")
    }

    static func longitude(_ radians: Double) -> String {
        degrees(abs(radians)) + "° " + (radians >= 0 ? "E" : "W")
    }

    /// Signed angle, for example "+12.5°".
    static func angle(_ radians: Double) -> String {
        (radians >= 0 ? "+" : "−") + degrees(abs(radians), digits: 1) + "°"
    }

    static func point(_ p: GeoPoint) -> String {
        latitude(p.latitude) + ", " + longitude(p.longitude)
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}
