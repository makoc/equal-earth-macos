import Foundation
import Metal
import Testing
@testable import EqualEarthExplorer

/// Checks that the inverse projection in Shaders.metal agrees with the Swift implementation.
struct GPUParityTests {
    @Test func inverseProjectionMatchesSwift() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalContext.self))
        let function = try #require(library.makeFunction(name: "ee_inverse_test"))
        let pipeline = try device.makeComputePipelineState(function: function)

        var input: [SIMD2<Float>] = []
        for y in stride(from: -1.4, through: 1.4, by: 0.05) {
            for x in stride(from: -2.8, through: 2.8, by: 0.05) {
                input.append(SIMD2(Float(x), Float(y)))
            }
        }
        let length = input.count * MemoryLayout<SIMD2<Float>>.stride
        let inBuffer = try #require(device.makeBuffer(bytes: input, length: length, options: .storageModeShared))
        let outBuffer = try #require(device.makeBuffer(length: length, options: .storageModeShared))

        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: input.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        let output = outBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: input.count)
        var compared = 0
        for (i, p) in input.enumerated() {
            let gpu = output[i]
            let swift = EqualEarth.inverse(SIMD2(Double(p.x), Double(p.y)))
            // Points within float rounding of the outline may land on either side.
            let nearEdge = abs(abs(Double(p.y)) - EqualEarth.yMax) < 1e-3
                || abs(abs(EqualEarth.inverseClamped(SIMD2(Double(p.x), Double(p.y))).longitude) - .pi) < 1e-3
            if nearEdge { continue }
            if let swift {
                #expect(abs(Double(gpu.x) - swift.longitude) < 1e-4, "λ at \(p)")
                #expect(abs(Double(gpu.y) - swift.latitude) < 1e-4, "φ at \(p)")
                compared += 1
            } else {
                #expect(gpu.x > 1e8, "GPU reports a point inside at \(p)")
            }
        }
        #expect(compared > 3000)
    }
}
