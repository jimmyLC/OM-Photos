import AVFoundation
import Foundation
import ImageIO

public enum SourceKind: String, Sendable {
    case wifi, usb
}

/// Where the photos come from: the camera over Wi-Fi, or its card over USB.
public protocol CameraSource: Sendable {
    var kind: SourceKind { get }
    /// Stable key for caches, e.g. "wifi-OM-3-P-XXXX" or "usb-/Volumes/OM SYSTEM".
    var cacheKey: String { get }
    func listFiles() async throws -> [MediaFile]
    /// Small image for the grid (encoded image data).
    func thumbnail(for file: MediaFile) async throws -> Data
    /// Large image for the viewer (encoded image data).
    func preview(for file: MediaFile) async throws -> Data
    func movieInfo(for file: MediaFile) async throws -> MovieInfo
    /// Copy the original file to `destination`; returns the number of bytes written.
    func download(_ file: MediaFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64
    /// Called once before an import (e.g. keep the camera awake).
    func prepareForImport() async
    /// Starting guess for the time estimate, in bytes per second.
    var typicalSpeed: Double { get }
    /// Permanently delete a file from the card.
    func delete(_ file: MediaFile) async throws
}

// MARK: - Wi-Fi

public struct WiFiSource: CameraSource {
    public let client: CameraClient
    public let cacheKey: String
    public var kind: SourceKind { .wifi }
    let settle: Duration

    public init(client: CameraClient, cameraID: String, settle: Duration = .milliseconds(2500)) {
        self.client = client
        self.cacheKey = "wifi-" + cameraID
        self.settle = settle
    }

    public func listFiles() async throws -> [MediaFile] {
        // The listing 404s if asked right after switching to play mode.
        try await client.switchMode(.play, settle: settle)
        var files: [MediaFile] = []
        for entry in try await list("/DCIM") where entry.isDirectory {
            files += try await list(entry.path).filter { !$0.isDirectory }.map(\.file)
        }
        return files
    }

    public func thumbnail(for file: MediaFile) async throws -> Data {
        try await client.data("get_thumbnail.cgi", query: ["DIR": file.path], timeout: 15)
    }

    public func preview(for file: MediaFile) async throws -> Data {
        try await client.data("get_screennail.cgi", query: ["DIR": file.path], timeout: 30)
    }

    public func movieInfo(for file: MediaFile) async throws -> MovieInfo {
        let xml = try await client.text("get_movfileinfo.cgi", query: ["DIR": file.path])
        return MovieInfo(duration: XML.value("playtime", in: xml).flatMap(TimeInterval.init),
                         resolution: XML.value("moviesize", in: xml))
    }

    public var typicalSpeed: Double { 3_000_000 }  // measured 3.1 MB/s on an OM-3

    public func prepareForImport() async {
        try? await client.switchMode(.play)
        try? await client.setTimeout(seconds: 1800)  // untested on the OM-3; harmless if refused
    }

    public func download(_ file: MediaFile, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        try await client.download(file.path, to: destination, progress: progress)
    }

    public func delete(_ file: MediaFile) async throws {
        try await client.switchMode(.play)
        let body = try await client.text("exec_erase.cgi", query: ["DIR": file.path], timeout: 15)
        // Some firmware answers 200 with an error text.
        if body.lowercased().contains("error") || body.lowercased().contains("fail") {
            throw CameraError.badResponse(XML.value("errorcode", in: body).map { "刪除失敗（代碼 \($0)）" } ?? "刪除失敗")
        }
    }

    private func list(_ dir: String) async throws -> [ListEntry] {
        do {
            return ListEntry.parse(try await client.text("get_imglist.cgi", query: ["DIR": dir], timeout: 30))
        } catch CameraError.http(status: 404, _) {
            return []  // empty card or folder
        }
    }
}

/// One row of get_imglist: "/DCIM/100OMSYS,PB260003.JPG,10971984,0,23930,33725".
struct ListEntry: Equatable {
    var file: MediaFile
    var isDirectory: Bool
    var path: String { file.path }

    static func parse(_ text: String) -> [ListEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count >= 6, p[0].hasPrefix("/"),
                  let size = Int64(p[2]), let attr = Int(p[3]), let d = Int(p[4]), let t = Int(p[5]) else { return nil }
            let file = MediaFile(path: p[0] + "/" + p[1], size: size, date: fatDate(d, t) ?? .distantPast,
                                 isProtected: attr & 0x01 != 0)
            return ListEntry(file: file, isDirectory: attr & 0x10 != 0)
        }
    }

    /// FAT date/time words, in the camera's local time.
    static func fatDate(_ d: Int, _ t: Int, calendar: Calendar = .current) -> Date? {
        var c = DateComponents()
        c.year = (d >> 9 & 0x7F) + 1980
        c.month = d >> 5 & 0x0F
        c.day = d & 0x1F
        c.hour = t >> 11 & 0x1F
        c.minute = t >> 5 & 0x3F
        c.second = (t & 0x1F) * 2
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return calendar.date(from: c)
    }
}

// MARK: - USB (the card mounted as a disk: camera USB mode "Storage")

public struct VolumeSource: CameraSource {
    public let root: URL
    public var kind: SourceKind { .usb }
    public var cacheKey: String { "usb-" + root.path }

    public init(root: URL) {
        self.root = root
    }

    /// True for a folder that looks like a camera card (has DCIM).
    public static func looksLikeCard(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path, isDirectory: &isDir) && isDir.boolValue
    }

    public var displayName: String {
        (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? root.lastPathComponent
    }

    public func url(for file: MediaFile) -> URL {
        root.appendingPathComponent(String(file.path.dropFirst()))
    }

    public func listFiles() async throws -> [MediaFile] {
        let root = root
        return try await Task.detached(priority: .userInitiated) {
            let dcim = root.appendingPathComponent("DCIM")
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isWritableKey, .isUserImmutableKey]
            guard let walker = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                throw CameraError.unreachable("讀不到記憶卡")
            }
            var out: [MediaFile] = []
            let base = root.standardizedFileURL.path
            while let url = walker.nextObject() as? URL {
                let v = try? url.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true, FileKind.of(url.lastPathComponent) != .other else { continue }
                let full = url.standardizedFileURL.path
                let rel = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : "/DCIM/" + url.lastPathComponent
                out.append(MediaFile(path: rel.hasPrefix("/") ? rel : "/" + rel,
                                     size: Int64(v?.fileSize ?? 0),
                                     date: v?.contentModificationDate ?? .distantPast,
                                     // The camera's "protect" sets the FAT read-only bit, which macOS
                                     // shows as the locked flag. A read-only mount is not "protected".
                                     isProtected: v?.isUserImmutable == true))
            }
            return out
        }.value
    }

    public func thumbnail(for file: MediaFile) async throws -> Data {
        try await image(for: file, maxPixels: 480)
    }

    public func preview(for file: MediaFile) async throws -> Data {
        try await image(for: file, maxPixels: 2400)
    }

    public func movieInfo(for file: MediaFile) async throws -> MovieInfo {
        let asset = AVURLAsset(url: url(for: file))
        let duration = try? await asset.load(.duration).seconds
        var resolution: String?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            resolution = "\(Int(abs(size.width)))x\(Int(abs(size.height)))"
        }
        return MovieInfo(duration: duration, resolution: resolution)
    }

    public var typicalSpeed: Double { 40_000_000 }  // measured 44.6 MB/s in Storage mode

    public func prepareForImport() async {}

    public func delete(_ file: MediaFile) async throws {
        let target = url(for: file)
        try await Task.detached {
            // Removed for good, like deleting on the camera (no Trash on the card).
            try FileManager.default.removeItem(at: target)
        }.value
    }

    public func download(_ file: MediaFile, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let source = url(for: file)
        return try await Task.detached(priority: .userInitiated) {
            guard let input = FileHandle(forReadingAtPath: source.path) else {
                throw CameraError.unreachable("讀不到 \(file.name)，記憶卡是否已拔除？")
            }
            defer { try? input.close() }
            _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                progress(copied)
            }
            return copied
        }.value
    }

    private func image(for file: MediaFile, maxPixels: Int) async throws -> Data {
        let url = url(for: file)
        if file.kind == .movie {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            let (cg, _) = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600))
            return try Imaging.jpegData(cg)
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = Imaging.downsample(src, maxPixels: maxPixels) else {
                throw CameraError.badResponse("無法讀取影像 \(file.name)")
            }
            return try Imaging.jpegData(cg)
        }.value
    }
}
