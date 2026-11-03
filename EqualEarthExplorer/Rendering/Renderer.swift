import Metal
import MetalKit
import Observation
import simd

// Uniform layouts. Must match the structs of the same name in Shaders.metal.

struct RasterUniforms {
    var viewToGeo: simd_float4x4
    var view: SIMD4<Float>
    var options: SIMD4<Float>
    var oceanColor: SIMD4<Float>
    var backgroundColor: SIMD4<Float>
    var tissotColor: SIMD4<Float>
}

struct LineUniforms {
    var geoToView: simd_float4x4
    var frameToView: simd_float4x4
    var view: SIMD4<Float>
    var style: SIMD4<Float>
    var color: SIMD4<Float>
}

/// One overlay uploaded to the GPU.
struct OverlayBuffer {
    let buffer: MTLBuffer
    let segmentCount: Int
    let space: SegmentList.Space
}

/// Metal device, pipelines and overlay geometry, shared by the map and the globe view.
@MainActor
@Observable
final class MetalContext {
    static let shared = MetalContext()

    static let tissotRadius = 3.0 * Double.pi / 180
    static let tissotStep = 30.0 * Double.pi / 180

    @ObservationIgnored let device: MTLDevice
    @ObservationIgnored let queue: MTLCommandQueue
    @ObservationIgnored private let rasterPipeline: MTLRenderPipelineState
    @ObservationIgnored private let linePipeline: MTLRenderPipelineState
    @ObservationIgnored private let sampler: MTLSamplerState
    @ObservationIgnored private let placeholder: MTLTexture

    // Built once at launch.
    @ObservationIgnored private var graticule: OverlayBuffer?
    @ObservationIgnored private var tissot: OverlayBuffer?
    @ObservationIgnored private var outline: OverlayBuffer?
    @ObservationIgnored private var cutLine: OverlayBuffer?
    @ObservationIgnored private var frameLines: OverlayBuffer?
    @ObservationIgnored private var northPole: OverlayBuffer?
    @ObservationIgnored private var southPole: OverlayBuffer?
    // Loaded from the bundled GeoJSON in the background.
    private(set) var coastlines: OverlayBuffer?
    private(set) var borders: OverlayBuffer?
    private(set) var rivers: OverlayBuffer?
    private(set) var states: OverlayBuffer?
    /// Country, capital and city names, most important first.
    private(set) var labels: [MapLabel] = []

    // Political base map: painted on first use (about 1 s, 180 MB of GPU memory).
    private(set) var politicalTexture: MTLTexture?
    private(set) var isPreparingPoliticalMap = false
    @ObservationIgnored private var politicalData: PoliticalData?
    @ObservationIgnored private var wantsPoliticalMap = false
    static let politicalTextureWidth = 8192

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this Mac.")
        }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeDefaultLibrary(bundle: .main)
            let raster = MTLRenderPipelineDescriptor()
            raster.label = "Raster"
            raster.vertexFunction = library.makeFunction(name: "raster_vertex")
            raster.fragmentFunction = library.makeFunction(name: "raster_fragment")
            raster.colorAttachments[0].pixelFormat = .bgra8Unorm
            rasterPipeline = try device.makeRenderPipelineState(descriptor: raster)

            let line = MTLRenderPipelineDescriptor()
            line.label = "Lines"
            line.vertexFunction = library.makeFunction(name: "line_vertex")
            line.fragmentFunction = library.makeFunction(name: "line_fragment")
            let attachment = line.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            linePipeline = try device.makeRenderPipelineState(descriptor: line)
        } catch {
            fatalError("Could not build the Metal pipelines: \(error)")
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.maxAnisotropy = 8
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        // 1 × 1 texture bound while the imagery is not available (the shader does not sample it).
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        placeholder = device.makeTexture(descriptor: textureDescriptor)!

        graticule = makeBuffer(Overlays.graticule())
        tissot = makeBuffer(Overlays.tissotOutlines(radius: Self.tissotRadius, step: 30))
        outline = makeBuffer(Overlays.mapOutline())
        let frame = Overlays.mapFrameLines()
        cutLine = makeBuffer(frame.cut)
        frameLines = makeBuffer(frame.frame)
        northPole = makeBuffer(Overlays.northPole())
        southPole = makeBuffer(Overlays.southPole())

        Task {
            let lists = await Task.detached(priority: .userInitiated) { () -> [SegmentList] in
                ["ne_50m_coastline",
                 "ne_50m_admin_0_boundary_lines_land",
                 "ne_50m_rivers_lake_centerlines",
                 "ne_50m_admin_1_states_provinces_lines"].map { name in
                    (try? GeoJSONLoader.load(resource: name)) ?? SegmentList(space: .geographic)
                }
            }.value
            coastlines = makeBuffer(lists[0])
            borders = makeBuffer(lists[1])
            rivers = makeBuffer(lists[2])
            states = makeBuffer(lists[3])

            let political = await Task.detached(priority: .userInitiated) { try? PoliticalData.load() }.value
            politicalData = political
            labels = political?.labels ?? []
            startPoliticalMapIfNeeded()
        }
    }

    /// Paints the political base map in the background the first time it is needed.
    func requestPoliticalMap() {
        wantsPoliticalMap = true
        startPoliticalMapIfNeeded()
    }

    private func startPoliticalMapIfNeeded() {
        guard wantsPoliticalMap, politicalTexture == nil, !isPreparingPoliticalMap, let data = politicalData else { return }
        isPreparingPoliticalMap = true
        let device = UncheckedBox(value: self.device)
        let width = Self.politicalTextureWidth
        Task {
            let texture = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<MTLTexture>? in
                (try? PoliticalMapRenderer.texture(data, width: width, device: device.value)).map { UncheckedBox(value: $0) }
            }.value
            politicalTexture = texture?.value
            isPreparingPoliticalMap = false
        }
    }

    private func makeBuffer(_ list: SegmentList) -> OverlayBuffer? {
        guard list.segmentCount > 0 else { return nil }
        let buffer = list.points.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { return nil }
        return OverlayBuffer(buffer: buffer, segmentCount: list.segmentCount, space: list.space)
    }

    // MARK: - Drawing

    /// Draws one frame. `pointScale` is pixels per point, used for line widths.
    func draw(in view: MTKView, mode: ViewMode, state: ViewState, imagery: ImageryStore, pointScale: Float) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        let layout = ViewLayout(size: size, mode: mode)
        let viewInfo = SIMD4<Float>(Float(size.width), Float(size.height), Float(layout.scale), Float(mode.rawValue))

        // Rotations into the view frame (see Overlays and Orientation for the conventions).
        let r = state.orientation
        let geoToView: simd_quatd
        let frameToView: simd_quatd
        switch mode {
        case .map:
            geoToView = r
            frameToView = Orientation.identity
        case .globe:
            // The globe looks at the map centre with north up; the roll shows in the frame lines.
            let g = Orientation.northUp(r)
            geoToView = g
            frameToView = g * r.inverse
        }

        let political = state.baseMap == .political
        let texture = political ? politicalTexture : imagery.texture
        let theme = political ? LineTheme.political : LineTheme.satellite
        var raster = RasterUniforms(
            viewToGeo: Orientation.matrix(geoToView.inverse),
            view: viewInfo,
            options: SIMD4(texture == nil ? 0 : 1,
                           state.showTissot ? 1 : 0,
                           Float(Self.tissotRadius),
                           Float(Self.tissotStep)),
            oceanColor: political ? SIMD4(SIMD3<Float>(PoliticalMapRenderer.ocean), 1) : SIMD4(0.11, 0.23, 0.38, 1),
            backgroundColor: Self.backgroundColor,
            tissotColor: SIMD4(1.0, 0.55, 0.15, 0.45))
        encoder.setRenderPipelineState(rasterPipeline)
        encoder.setFragmentBytes(&raster, length: MemoryLayout<RasterUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture ?? placeholder, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(linePipeline)
        let lines = LineUniforms(geoToView: Orientation.matrix(geoToView),
                                 frameToView: Orientation.matrix(frameToView),
                                 view: viewInfo,
                                 style: .zero,
                                 color: .zero)
        let w = pointScale * (mode == .map ? 1 : 0.8)
        func line(_ overlay: OverlayBuffer?, _ color: SIMD4<Float>, width: Float, backAlpha: Float = 0) {
            guard let overlay else { return }
            var u = lines
            u.style = SIMD4(Float(overlay.space.rawValue), width * w / 2, backAlpha, 0)
            u.color = color
            encoder.setVertexBuffer(overlay.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<LineUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: overlay.segmentCount)
        }

        if state.showGraticule { line(graticule, theme.graticule, width: 1) }
        if state.showRivers { line(rivers, theme.rivers, width: 0.8) }
        if state.showStates { line(states, theme.states, width: 0.7) }
        if state.showBorders { line(borders, theme.borders, width: 0.9) }
        if state.showCoastlines { line(coastlines, theme.coastlines, width: 1) }
        if state.showTissot { line(tissot, SIMD4(1, 0.55, 0.15, 1), width: 1.2) }
        if state.showOutline {
            switch mode {
            case .map:
                line(outline, theme.outline, width: 1.5)
            case .globe:
                line(frameLines, SIMD4(0.35, 0.85, 1, 0.9), width: 1.2, backAlpha: 0.3)
                line(cutLine, SIMD4(1, 0.25, 0.25, 1), width: 2, backAlpha: 0.45)
            }
            line(northPole, SIMD4(1, 0.25, 0.25, 1), width: 9)
            line(southPole, SIMD4(0.3, 0.55, 1, 1), width: 9)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// Dark neutral background behind the map and the globe.
    static let backgroundColor = SIMD4<Float>(0.09, 0.09, 0.1, 1)
}

/// Line colours that read well on each base map.
struct LineTheme {
    var graticule: SIMD4<Float>
    var coastlines: SIMD4<Float>
    var borders: SIMD4<Float>
    var states: SIMD4<Float>
    var rivers: SIMD4<Float>
    var outline: SIMD4<Float>

    static let satellite = LineTheme(graticule: SIMD4(1, 1, 1, 0.35),
                                     coastlines: SIMD4(0.97, 0.97, 0.92, 0.95),
                                     borders: SIMD4(1, 0.86, 0.45, 0.75),
                                     states: SIMD4(1, 1, 1, 0.4),
                                     rivers: SIMD4(0.55, 0.78, 1, 0.75),
                                     outline: SIMD4(0.85, 0.85, 0.85, 1))

    static let political = LineTheme(graticule: SIMD4(0.2, 0.35, 0.55, 0.3),
                                     coastlines: SIMD4(0.25, 0.42, 0.62, 0.9),
                                     borders: SIMD4(0.35, 0.3, 0.3, 0.85),
                                     states: SIMD4(0.45, 0.42, 0.42, 0.55),
                                     rivers: SIMD4(0.36, 0.6, 0.85, 0.9),
                                     outline: SIMD4(0.85, 0.85, 0.85, 1))
}
