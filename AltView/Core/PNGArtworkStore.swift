import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PNGArtwork {
    let id: UUID
    let name: String
    let image: CGImage
}

enum ArtworkFailure: Error, LocalizedError {
    case invalidPNG, tooLarge, animatedPNG
    var errorDescription: String? {
        switch self {
        case .invalidPNG: return "Choose a readable PNG image. The current artwork has been kept."
        case .tooLarge: return "Use a PNG under 20 MB, no larger than 16,384 pixels per side or 40 megapixels."
        case .animatedPNG: return "Use a single-frame PNG. AltView animates the banner with Slide or Reveal."
        }
    }
}

/// File I/O and decoding are queue-confined. Imported PNGs are copied into the
/// sandbox, so reopening never requires a bookmark or the original file.
final class PNGArtworkStore {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.suku.AltView.artwork", qos: .userInitiated)
    static let maximumBytes = 20 * 1024 * 1024
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AltView/Artwork", isDirectory: true)
    }
    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= maximumBytes else { throw ArtworkFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ArtworkFailure.invalidPNG }
        guard CGImageSourceGetCount(source) == 1 else { throw ArtworkFailure.animatedPNG }
        guard width <= 16_384, height <= 16_384, width * height <= 40_000_000 else { throw ArtworkFailure.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ArtworkFailure.invalidPNG }
        return image
    }
    private func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw ArtworkFailure.tooLarge }
        return data
    }
    func importPNG(from url: URL, completion: @escaping (Result<PNGArtwork, Error>) -> Void) {
        let access = url.startAccessingSecurityScopedResource()
        queue.async {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> PNGArtwork in
                let data = try self.read(url)
                let image = try Self.decode(data)
                let id = UUID()
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try data.write(to: self.path(id), options: .atomic)
                return PNGArtwork(id: id, name: url.lastPathComponent, image: image)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func load(id: UUID, name: String, completion: @escaping (Result<PNGArtwork, Error>) -> Void) {
        queue.async {
            let result = Result { try PNGArtwork(id: id, name: name, image: Self.decode(self.read(self.path(id)))) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func discard(id: UUID) { queue.async { try? FileManager.default.removeItem(at: self.path(id)) } }
    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("png") }
}
