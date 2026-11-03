import CoreGraphics
import Foundation
import simd
import Testing
@testable import EqualEarthExplorer

struct PoliticalMapTests {
    private func data() throws -> PoliticalData {
        try PoliticalData.load(bundle: Bundle(for: MetalContext.self))
    }

    @Test func bundledDataLoads() throws {
        let d = try data()
        #expect(d.countries.count == 242)
        #expect(d.lakes.count > 300)
        #expect(d.labels.contains { $0.kind == .capital && $0.text == "Berlin" })
        #expect(d.labels.contains { $0.kind == .city && $0.text == "New York" })
        #expect(d.labels.contains { $0.kind == .country && $0.text == "BRAZIL" })
        // Sorted by priority: the first labels are large countries.
        #expect(d.labels.first?.kind == .country)
    }

    /// Colour of the painted map at a geographic position (degrees).
    private func pixel(_ image: CGImage, lon: Double, lat: Double) throws -> SIMD3<Double> {
        let x = min(image.width - 1, Int((lon + 180) / 360 * Double(image.width)))
        let y = min(image.height - 1, Int((90 - lat) / 180 * Double(image.height)))
        let bytes = try #require(image.dataProvider?.data as Data?)
        let i = y * image.bytesPerRow + x * 4
        return SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2])) / 255
    }

    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        simd_length(a - b) < 0.02
    }

    @Test func paintsOceanLandLakesAndAntarctica() throws {
        let image = try #require(PoliticalMapRenderer.image(try data(), width: 1440))
        #expect(image.width == 1440 && image.height == 720)
        let ocean = PoliticalMapRenderer.ocean
        #expect(close(try pixel(image, lon: -150, lat: 0), ocean))                   // Pacific
        #expect(!close(try pixel(image, lon: 10.5, lat: 51), ocean))                 // Germany
        #expect(!close(try pixel(image, lon: -100, lat: 40), ocean))                 // United States
        #expect(close(try pixel(image, lon: -86.8, lat: 43.5), ocean))                // Lake Michigan
        #expect(close(try pixel(image, lon: 30, lat: -85), PoliticalMapRenderer.antarctica))
        // North is the first row: Greenland at 72° N, not the Southern Ocean.
        #expect(!close(try pixel(image, lon: -40, lat: 72), ocean))
    }
}
