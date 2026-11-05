import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import EqualEarthExplorer

/// The satellite JPEG must reach the GPU with its true colours (regression: the texture
/// once showed only luminance and blue, because ImageIO's YCbCr image was copied raw).
struct TextureColorTests {
    private let stripes: [(name: String, rgb: SIMD3<Double>)] = [
        ("red", SIMD3(1, 0, 0)),
        ("green", SIMD3(0, 1, 0)),
        ("blue", SIMD3(0, 0, 1)),
        ("tan", SIMD3(0.8, 0.65, 0.4)),
    ]

    private func makeJPEG(width: Int, height: Int) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let stripeWidth = width / stripes.count
        for (i, stripe) in stripes.enumerated() {
            ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(stripe.rgb.x), CGFloat(stripe.rgb.y), CGFloat(stripe.rgb.z), 1])!)
            ctx.fill(CGRect(x: i * stripeWidth, y: 0, width: stripeWidth, height: height))
        }
        let image = try #require(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "texture-colour-test-\(UUID().uuidString).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func jpegKeepsItsColours() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try makeJPEG(width: 1024, height: 256)
        defer { try? FileManager.default.removeItem(at: url) }

        // Same path as the app, including the downscale.
        let texture = try TextureFactory.texture(contentsOf: url, maxPixelSize: 512, device: device)
        #expect(texture.width == 512 && texture.height == 128)
        #expect(texture.pixelFormat == .rgba8Unorm)
        #expect(texture.mipmapLevelCount > 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        let stripeWidth = texture.width / stripes.count
        for (i, stripe) in stripes.enumerated() {
            let x = i * stripeWidth + stripeWidth / 2
            texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, 64, 1, 1), mipmapLevel: 0)
            let rgb = SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2])) / 255
            let d = rgb - stripe.rgb
            let error = max(abs(d.x), abs(d.y), abs(d.z))
            #expect(error < 0.08, "\(stripe.name): got \(rgb)")
        }
    }
}
