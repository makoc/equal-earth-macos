import CoreGraphics
import Metal

/// Paints the political base map (ocean, country fills, lakes) into an equirectangular
/// image with Core Graphics. The result is sampled by the same shader as the satellite
/// imagery; borders, rivers and labels are drawn on top as vectors.
enum PoliticalMapRenderer {
    static let ocean = SIMD3<Double>(0.66, 0.80, 0.90)
    static let antarctica = SIMD3<Double>(0.95, 0.96, 0.97)
    /// Pastel colours for Natural Earth's MAPCOLOR7 classes 1…7.
    static let palette: [SIMD3<Double>] = [
        SIMD3(0.98, 0.86, 0.62),
        SIMD3(0.80, 0.89, 0.66),
        SIMD3(0.97, 0.77, 0.74),
        SIMD3(0.86, 0.81, 0.93),
        SIMD3(0.99, 0.93, 0.70),
        SIMD3(0.93, 0.81, 0.69),
        SIMD3(0.84, 0.86, 0.74),
    ]

    /// Image of `width` × `width / 2` pixels; x = longitude −180…180°, top row = 90° N.
    static func image(_ data: PoliticalData, width: Int) -> CGImage? {
        let height = width / 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        func color(_ c: SIMD3<Double>) -> CGColor {
            CGColor(colorSpace: space, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1])!
        }

        ctx.setFillColor(color(ocean))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Work in degrees. Core Graphics has y up, and the bitmap's first row is its top,
        // so latitude +90° ends up in the first row, as the shader expects.
        ctx.scaleBy(x: CGFloat(width) / 360, y: CGFloat(height) / 180)
        ctx.translateBy(x: 180, y: 90)
        ctx.setShouldAntialias(true)
        // A thin outline in the fill colour hides hairline gaps between neighbours.
        ctx.setLineWidth(360 / CGFloat(width) * 1.2)
        ctx.setLineJoin(.round)

        func addPolygon(_ polygon: GeoPolygon) {
            for ring in polygon where ring.count > 2 {
                ctx.addLines(between: ring.map { CGPoint(x: $0.x, y: $0.y) })
                ctx.closePath()
            }
        }

        for country in data.countries {
            let c = color(country.isAntarctica ? antarctica : palette[(max(1, min(7, country.mapColor))) - 1])
            ctx.setFillColor(c)
            ctx.setStrokeColor(c)
            for polygon in country.polygons {
                addPolygon(polygon)
                // Even-odd keeps the holes (lakes inside a country, enclaves) open.
                ctx.fillPath(using: .evenOdd)
                if let outline = polygon.first, outline.count > 2 {
                    ctx.addLines(between: outline.map { CGPoint(x: $0.x, y: $0.y) })
                    ctx.closePath()
                    ctx.strokePath()
                }
            }
        }

        ctx.setFillColor(color(ocean))
        for lake in data.lakes {
            addPolygon(lake)
            ctx.fillPath(using: .evenOdd)
        }
        return ctx.makeImage()
    }

    static func texture(_ data: PoliticalData, width: Int, device: MTLDevice) throws -> MTLTexture {
        guard let image = image(data, width: width) else { throw DownloadError.undecodable }
        return try TextureFactory.texture(from: image, device: device)
    }
}
