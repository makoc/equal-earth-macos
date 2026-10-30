import Foundation

/// Reads the LineString and MultiLineString features of a Natural Earth GeoJSON file.
enum GeoJSONLoader {
    private struct FeatureCollection: Decodable {
        let features: [Feature]
    }

    private struct Feature: Decodable {
        let geometry: Geometry?
    }

    private struct Geometry: Decodable {
        let lines: [[[Double]]]

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "LineString":
                lines = [try c.decode([[Double]].self, forKey: .coordinates)]
            case "MultiLineString":
                lines = try c.decode([[[Double]]].self, forKey: .coordinates)
            default:
                lines = []
            }
        }
    }

    /// Loads a bundled GeoJSON resource as geographic segments.
    static func load(resource: String, bundle: Bundle = .main) throws -> SegmentList {
        guard let url = bundle.url(forResource: resource, withExtension: "geojson") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: resource + ".geojson"])
        }
        return try load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> SegmentList {
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
        var list = SegmentList(space: .geographic)
        for feature in collection.features {
            for line in feature.geometry?.lines ?? [] {
                // GeoJSON positions are [longitude, latitude] in degrees.
                let points = line.compactMap { p -> SIMD3<Double>? in
                    guard p.count >= 2 else { return nil }
                    return Sphere.vector(longitude: p[0] * .pi / 180, latitude: p[1] * .pi / 180)
                }
                list.addPolyline(points)
            }
        }
        return list
    }
}
