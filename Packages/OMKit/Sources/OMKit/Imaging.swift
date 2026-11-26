import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Imaging {
    /// Decode and shrink, applying the EXIF orientation.
    public static func downsample(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    public static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(src, maxPixels: maxPixels)
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.85) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraError.badResponse("JPEG 編碼失敗")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CameraError.badResponse("JPEG 編碼失敗") }
        return out as Data
    }
}

/// Thumbnails and previews: memory cache plus a disk cache under Caches,
/// so a camera's thumbnails load instantly the next time.
public actor ImageStore {
    public enum Size: String, Sendable {
        case thumbnail, preview
        var maxPixels: Int { self == .thumbnail ? 480 : 2400 }
    }

    private let memory = NSCache<NSString, Box>()
    private let directory: URL?
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    public init(directory: URL? = ImageStore.defaultDirectory()) {
        self.directory = directory
        memory.countLimit = 1500
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OM Photos/images", isDirectory: true)
    }

    /// Cached image if already in memory (no waiting).
    public func cached(_ file: MediaFile, size: Size, source: String) -> CGImage? {
        memory.object(forKey: Self.key(file, size, source) as NSString)?.image
    }

    public func image(for file: MediaFile, size: Size, from source: any CameraSource) async -> CGImage? {
        let key = Self.key(file, size, source.cacheKey)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        if let running = inFlight[key] { return await running.value }
        let disk = directory?.appendingPathComponent(Self.hash(key) + ".jpg")
        let task = Task<CGImage?, Never> {
            if let disk, let data = try? Data(contentsOf: disk), let img = Imaging.decode(data, maxPixels: size.maxPixels) {
                return img
            }
            guard !Task.isCancelled else { return nil }
            let data: Data
            do {
                data = size == .thumbnail ? try await source.thumbnail(for: file) : try await source.preview(for: file)
            } catch {
                return nil
            }
            guard let img = Imaging.decode(data, maxPixels: size.maxPixels) else { return nil }
            if let disk { try? data.write(to: disk, options: .atomic) }
            return img
        }
        inFlight[key] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight[key] = nil
        if let result { memory.setObject(Box(result), forKey: key as NSString) }
        return result
    }

    static func key(_ file: MediaFile, _ size: Size, _ source: String) -> String {
        "\(source)|\(file.path)|\(file.size)|\(Int(file.date.timeIntervalSince1970))|\(size.rawValue)"
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
