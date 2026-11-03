import Foundation

/// A polygon as rings of (longitude, latitude) in degrees; the first ring is the outline,
/// the others are holes.
typealias GeoPolygon = [[SIMD2<Double>]]

struct CountryShape: Sendable {
    var name: String
    /// Natural Earth MAPCOLOR7: 1…7, chosen so that neighbouring countries differ.
    var mapColor: Int
    var isAntarctica: Bool
    var polygons: [GeoPolygon]
}

struct MapLabel: Sendable {
    enum Kind: Sendable {
        case country
        case capital
        case city
    }

    var text: String
    var kind: Kind
    /// Geographic unit vector of the anchor point.
    var position: SIMD3<Double>
    /// Lower values are placed first when labels compete for space.
    var priority: Double
}

/// The bundled Natural Earth layers of the political base map (prepared by
/// `Tools/prepare_natural_earth.py`).
struct PoliticalData: Sendable {
    var countries: [CountryShape]
    var lakes: [GeoPolygon]
    var labels: [MapLabel]

    static func load(bundle: Bundle = .main) throws -> PoliticalData {
        func data(_ name: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: "geojson") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name + ".geojson"])
            }
            return try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        let countryFeatures = try decoder.decode(FeatureCollection<CountryProperties>.self, from: data("ne_50m_admin_0_countries")).features
        let lakeFeatures = try decoder.decode(FeatureCollection<Ignored>.self, from: data("ne_50m_lakes")).features
        let placeFeatures = try decoder.decode(FeatureCollection<PlaceProperties>.self, from: data("ne_50m_populated_places_selected")).features

        let countries = countryFeatures.map {
            CountryShape(name: $0.properties.name,
                         mapColor: $0.properties.mapcolor7,
                         isAntarctica: $0.properties.antarctica,
                         polygons: $0.geometry.polygons)
        }
        let lakes = lakeFeatures.flatMap(\.geometry.polygons)

        var labels: [MapLabel] = []
        let degree = Double.pi / 180
        for c in countryFeatures where c.properties.labelrank <= 5 && !c.properties.antarctica {
            let rank = Double(c.properties.labelrank)
            // Large countries first, then capitals compete with the smaller countries.
            labels.append(MapLabel(text: c.properties.name.uppercased(),
                                   kind: .country,
                                   position: Sphere.vector(longitude: c.properties.label_x * degree,
                                                           latitude: c.properties.label_y * degree),
                                   priority: rank <= 3 ? rank : rank + 1.5))
        }
        for p in placeFeatures {
            guard let point = p.geometry.point else { continue }
            // Within each group, bigger cities win: priority grows as the population falls.
            let size = 1 - min(1, log10(max(1, p.properties.population)) / 8)
            labels.append(MapLabel(text: p.properties.name,
                                   kind: p.properties.capital ? .capital : .city,
                                   position: Sphere.vector(longitude: point.x * degree, latitude: point.y * degree),
                                   priority: (p.properties.capital ? 3.5 : 4.5) + size))
        }
        labels.sort { $0.priority < $1.priority }
        return PoliticalData(countries: countries, lakes: lakes, labels: labels)
    }

    // MARK: - GeoJSON decoding

    private struct FeatureCollection<Properties: Decodable>: Decodable {
        let features: [Feature<Properties>]
    }

    private struct Feature<Properties: Decodable>: Decodable {
        let properties: Properties
        let geometry: Geometry
    }

    private struct Ignored: Decodable {}

    private struct CountryProperties: Decodable {
        let name: String
        let mapcolor7: Int
        let labelrank: Int
        let label_x: Double
        let label_y: Double
        let antarctica: Bool
    }

    private struct PlaceProperties: Decodable {
        let name: String
        let capital: Bool
        let population: Double
    }

    /// Point, Polygon and MultiPolygon geometries.
    private struct Geometry: Decodable {
        var polygons: [GeoPolygon] = []
        var point: SIMD2<Double>?

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func rings(_ raw: [[[Double]]]) -> GeoPolygon {
                raw.map { ring in ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil } }
            }
            switch try c.decode(String.self, forKey: .type) {
            case "Point":
                let p = try c.decode([Double].self, forKey: .coordinates)
                if p.count >= 2 { point = SIMD2(p[0], p[1]) }
            case "Polygon":
                polygons = [rings(try c.decode([[[Double]]].self, forKey: .coordinates))]
            case "MultiPolygon":
                polygons = try c.decode([[[[Double]]]].self, forKey: .coordinates).map(rings)
            default:
                break
            }
        }
    }
}
