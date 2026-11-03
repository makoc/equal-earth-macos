import Foundation
import ImageIO
import Metal
import MetalKit
import Observation

/// Wraps a value that is handed between isolation domains exactly once.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// Downloads (after explicit consent), caches and decodes the NASA Blue Marble imagery.
@MainActor
@Observable
final class ImageryStore {
    enum Phase: Equatable {
        case missing
        case downloading
        case decoding
        case ready
        case failed(String)
    }

    /// July: the northern hemisphere has little seasonal snow, so the continents show their land cover.
    static let sourceURL = URL(string: "https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-topography-bathymetry/july/world.topo.bathy.200407.3x21600x10800.jpg")!
    static let sourcePage = URL(string: "https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-topography-bathymetry/")!
    static let expectedBytes: Int64 = 27_201_049
    /// Longest texture edge. 8192 × 4096 RGBA with mipmaps needs about 180 MB of GPU memory.
    nonisolated static let textureWidth = 8192

    private(set) var phase: Phase = .missing
    private(set) var receivedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = ImageryStore.expectedBytes
    private(set) var texture: MTLTexture?

    /// Controls the consent and progress sheet.
    var isSheetPresented = false

    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var didStart = false

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }

    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/<bundle id>/Imagery/…` when sandboxed.
    var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appending(path: Bundle.main.bundleIdentifier ?? "EqualEarthExplorer", directoryHint: .isDirectory)
            .appending(path: "Imagery", directoryHint: .isDirectory)
        return folder.appending(path: Self.sourceURL.lastPathComponent)
    }

    var isCached: Bool { FileManager.default.fileExists(atPath: cacheURL.path(percentEncoded: false)) }

    /// Called once at launch: loads the cached file, or asks for consent to download it.
    func start() {
        guard !didStart else { return }
        didStart = true
        removeStaleImages()
        if isCached {
            loadCachedImage()
        } else {
            isSheetPresented = true
        }
    }

    func download() {
        guard phase != .downloading else { return }
        phase = .downloading
        receivedBytes = 0
        totalBytes = Self.expectedBytes
        let (task, observation) = Self.makeDownloadTask(source: Self.sourceURL, destination: cacheURL, store: self)
        self.task = task
        self.progressObservation = observation
        task.resume()
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
        progressObservation = nil
        phase = .missing
    }

    func deleteCache() {
        cancelDownload()
        try? FileManager.default.removeItem(at: cacheURL)
        texture = nil
        phase = .missing
    }

    // MARK: - Private

    /// Deletes images from earlier versions of the app (for example the December image).
    private func removeStaleImages() {
        let fm = FileManager.default
        let folder = cacheURL.deletingLastPathComponent()
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent != cacheURL.lastPathComponent {
            try? fm.removeItem(at: file)
        }
    }

    private func updateProgress(received: Int64, total: Int64) {
        guard phase == .downloading else { return }
        receivedBytes = received
        if total > 0 { totalBytes = total }
    }

    private func finishDownload(_ result: Result<Void, Error>) {
        task = nil
        progressObservation = nil
        switch result {
        case .success:
            receivedBytes = totalBytes
            loadCachedImage()
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadCachedImage() {
        phase = .decoding
        let url = cacheURL
        let device = UncheckedBox(value: MetalContext.shared.device)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<UncheckedBox<MTLTexture>, Error> in
                Result { UncheckedBox(value: try Self.makeTexture(from: url, device: device.value)) }
            }.value
            switch result {
            case .success(let box):
                texture = box.value
                phase = .ready
                isSheetPresented = false
            case .failure(let error):
                // A damaged file would fail again on every launch: remove it.
                try? FileManager.default.removeItem(at: url)
                phase = .failed("The cached image could not be decoded (\(error.localizedDescription)). Please download it again.")
                isSheetPresented = true
            }
        }
    }

    /// Created outside the main actor, so the URLSession and KVO (key-value observing)
    /// callbacks are not treated as main-actor code when they run on background threads.
    nonisolated private static func makeDownloadTask(source: URL,
                                                     destination: URL,
                                                     store: ImageryStore) -> (URLSessionDownloadTask, NSKeyValueObservation) {
        let task = URLSession.shared.downloadTask(with: source) { [weak store] tempURL, response, error in
            let result: Result<Void, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(DownloadError.httpStatus(http.statusCode))
            } else if let tempURL {
                // The temporary file is deleted when this handler returns: move it now.
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.moveItem(at: tempURL, to: destination)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(URLError(.unknown))
            }
            Task { @MainActor in store?.finishDownload(result) }
        }
        let observation = task.progress.observe(\.fractionCompleted) { [weak store] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in store?.updateProgress(received: received, total: total) }
        }
        return (task, observation)
    }

    nonisolated private static func makeTexture(from url: URL, device: MTLDevice) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DownloadError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: textureWidth,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DownloadError.undecodable
        }
        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(cgImage: image, options: [
            .generateMipmaps: true,
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int)
    case undecodable

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "The server answered with HTTP status \(code)."
        case .undecodable: "The file is not a readable image."
        }
    }
}
