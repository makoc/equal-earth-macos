import CoreGraphics
import Foundation
import ImageIO
import Metal

/// Turns a CGImage into a mipmapped RGBA texture.
///
/// ImageIO may hand out JPEG images whose pixels are still in the JPEG's YCbCr layout
/// (luminance plus blue- and red-difference planes). Passing such an image straight to
/// `MTKTextureLoader` copies the raw planes, which looks like "luminance and blue only".
/// Redrawing the image into an RGBA bitmap first makes Core Graphics do the colour
/// conversion, so the texture always holds true sRGB values.
enum TextureFactory {
    enum Failure: LocalizedError {
        case bitmap
        case texture

        var errorDescription: String? {
            switch self {
            case .bitmap: "The image could not be converted to RGBA."
            case .texture: "The GPU texture could not be created."
            }
        }
    }

    /// RGBA, 8 bits per channel, sRGB, opaque. Row 0 is the top of the image.
    static func rgbaBitmap(_ image: CGImage, width: Int, height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.bitmap
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// Decodes an image file, scaled down so that its longer edge is at most `maxPixelSize`.
    static func texture(contentsOf url: URL, maxPixelSize: Int, device: MTLDevice) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DownloadError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DownloadError.undecodable
        }
        return try texture(from: image, device: device)
    }

    static func texture(from image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = image.width, height = image.height
        let bitmap = try rgbaBitmap(image, width: width, height: height)
        guard let bytes = bitmap.data else { throw Failure.bitmap }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.texture }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: bitmap.bytesPerRow)

        guard let queue = device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { throw Failure.texture }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return texture
    }
}
