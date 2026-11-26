import Foundation
import Observation
import Photos

// MARK: - Ledger

/// Remembers which files this device already imported, so they are not imported
/// again even after the copies are moved or deleted. Wi-Fi and USB share it: a file
/// is identified by its card path, size and shooting time.
public final class ImportLedger: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var location: String?
        public var importedAt: Date
    }

    private var entries: [String: Entry]
    private let url: URL?
    private let lock = NSLock()

    public init(url: URL? = ImportLedger.defaultURL()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    public static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("OM Transfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("imported.json")
    }

    static func key(_ file: MediaFile) -> String {
        // FAT times have 2-second resolution; Wi-Fi and USB report the same value.
        "\(file.path)|\(file.size)|\(Int(file.date.timeIntervalSince1970) / 2)"
    }

    public func contains(_ file: MediaFile) -> Bool {
        lock.withLock { entries[Self.key(file)] != nil }
    }

    public func isImported(_ item: MediaItem) -> Bool {
        lock.withLock { item.files.allSatisfy { entries[Self.key($0)] != nil } }
    }

    public func importedIDs(in items: [MediaItem]) -> Set<MediaItem.ID> {
        Set(items.filter(isImported).map(\.id))
    }

    public func record(_ files: [MediaFile], location: String?) {
        let snapshot: [String: Entry] = lock.withLock {
            for f in files { entries[Self.key(f)] = Entry(location: location, importedAt: .now) }
            return entries
        }
        if let url, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public var count: Int { lock.withLock { entries.count } }
}

// MARK: - Destinations

public protocol ImportDestination: Sendable {
    /// Shown to the user, e.g. "照片圖庫" or "OM Transfer 資料夾".
    var title: String { get }
    /// Ask for permission or check the folder; throws a readable error.
    func prepare() async throws
    /// Take ownership of the downloaded files (temporary URLs) of one item.
    /// Returns where they went, for the ledger.
    func store(_ item: MediaItem, files: [(file: MediaFile, url: URL)]) async throws -> String?
}

public struct ImportError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Files go into `root` (or `<root>/<YYYY-MM-DD>/` with `daySubfolders`);
/// never overwrites a different file.
public struct FolderDestination: ImportDestination {
    public let root: URL
    public let daySubfolders: Bool
    public var title: String { root.lastPathComponent }

    public init(root: URL, daySubfolders: Bool = false) {
        self.root = root
        self.daySubfolders = daySubfolders
    }

    public static func defaultRoot() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("OM Transfer", isDirectory: true)
    }

    public func prepare() async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError("找不到資料夾「\(root.path)」。")
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            throw ImportError("無法寫入資料夾「\(root.lastPathComponent)」。")
        }
    }

    public func store(_ item: MediaItem, files: [(file: MediaFile, url: URL)]) async throws -> String? {
        let fm = FileManager.default
        var folder = root
        for (file, temp) in files {
            if daySubfolders {
                folder = root.appendingPathComponent(Self.dayName(file.date), isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var target = folder.appendingPathComponent(file.name)
            var n = 1
            while fm.fileExists(atPath: target.path) {
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if size == file.size {  // already there (e.g. imported before the ledger existed)
                    try? fm.removeItem(at: temp)
                    break
                }
                target = folder.appendingPathComponent("\(file.stem) (\(n)).\((file.name as NSString).pathExtension)")
                n += 1
            }
            if fm.fileExists(atPath: temp.path) {
                try fm.moveItem(at: temp, to: target)
                try? fm.setAttributes([.creationDate: file.date, .modificationDate: file.date], ofItemAtPath: target.path)
            }
        }
        return folder.path
    }

    static func dayName(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The Photos library. RAW+JPG becomes one photo (JPG shown, RAW kept as the
/// alternate resource), like importing in the Photos app.
public struct PhotoLibraryDestination: ImportDestination {
    public var title: String { "照片圖庫" }

    public init() {}

    public func prepare() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ImportError("沒有加入照片的權限。請到 設定 › 隱私權 › 照片 允許 OM Transfer「只加入照片」。")
        }
    }

    public func store(_ item: MediaItem, files: [(file: MediaFile, url: URL)]) async throws -> String? {
        let jpg = files.first { $0.file.kind == .jpg }
        let raw = files.first { $0.file.kind == .raw }
        let movie = files.first { $0.file.kind == .movie }
        let date = item.date
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date
            func add(_ type: PHAssetResourceType, _ entry: (file: MediaFile, url: URL)) {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                options.originalFilename = entry.file.name
                request.addResource(with: type, fileURL: entry.url, options: options)
            }
            if let movie {
                add(.video, movie)
            } else if let jpg, let raw {
                add(.photo, jpg)
                add(.alternatePhoto, raw)
            } else if let only = jpg ?? raw {
                add(.photo, only)
            }
        }
        for f in files { try? FileManager.default.removeItem(at: f.url) }  // in case Photos copied instead of moved
        return title
    }
}

// MARK: - Importer

public struct ImportSummary: Equatable, Sendable {
    public var imported = 0
    public var failed: [String] = []
    public var bytes: Int64 = 0
    public var seconds: TimeInterval = 0
    public var location: String?
    public var error: String?
    public var cancelled = false
}

/// Runs one import at a time: photos first, videos last, each file checked for size.
@MainActor @Observable
public final class Importer {
    public enum Phase: Equatable {
        case idle, running, finished(ImportSummary)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var totalItems = 0
    public private(set) var doneItems = 0
    public private(set) var totalBytes: Int64 = 0
    public private(set) var doneBytes: Int64 = 0
    public private(set) var currentName = ""
    /// Items whose import failed in the last run (for "retry").
    public private(set) var failedItems: [MediaItem] = []

    public let ledger: ImportLedger
    /// Called with true when an import starts and false when it ends (keep the device awake).
    public var onRunningChange: ((Bool) -> Void)?
    /// Called after each item is stored.
    public var onItemImported: ((MediaItem) -> Void)?

    private var task: Task<Void, Never>?
    private var started = Date()
    private var fallbackSpeed: Double = 3_000_000
    private let tempDirectory: URL
    private let retries: Int

    public init(ledger: ImportLedger, tempDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("OM Transfer Import", isDirectory: true), retries: Int = 1) {
        self.ledger = ledger
        self.tempDirectory = tempDirectory
        self.retries = retries
    }

    public var isRunning: Bool { phase == .running }
    public var fraction: Double { totalBytes > 0 ? min(Double(doneBytes) / Double(totalBytes), 1) : 0 }

    /// Bytes per second so far (or the source's typical speed at the start).
    public var speed: Double {
        let elapsed = Date().timeIntervalSince(started)
        return elapsed > 3 && doneBytes > 0 ? Double(doneBytes) / elapsed : fallbackSpeed
    }

    public var remaining: TimeInterval? {
        guard isRunning, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / max(speed, 1)
    }

    /// Items of `items` not imported yet, in import order.
    public func newItems(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { !ledger.isImported($0) }
    }

    public static func estimate(_ items: [MediaItem], source: any CameraSource) -> (count: Int, bytes: Int64, seconds: TimeInterval) {
        let bytes = items.reduce(0) { $0 + $1.size }
        return (items.count, bytes, Double(bytes) / source.typicalSpeed)
    }

    public func start(_ items: [MediaItem], from source: any CameraSource, to destination: any ImportDestination) {
        guard !isRunning, !items.isEmpty else { return }
        let ordered = items.filter { !$0.isVideo }.sorted { $0.date < $1.date }
            + items.filter(\.isVideo).sorted { $0.date < $1.date }
        totalItems = ordered.count
        doneItems = 0
        totalBytes = ordered.reduce(0) { $0 + $1.size }
        doneBytes = 0
        currentName = ""
        failedItems = []
        fallbackSpeed = source.typicalSpeed
        started = Date()
        phase = .running
        onRunningChange?(true)
        task = Task { await run(ordered, source: source, destination: destination) }
    }

    public func cancel() {
        task?.cancel()
    }

    public func dismissSummary() {
        if case .finished = phase { phase = .idle }
    }

    private func run(_ items: [MediaItem], source: any CameraSource, destination: any ImportDestination) async {
        var summary = ImportSummary()
        defer {
            summary.seconds = Date().timeIntervalSince(started)
            summary.cancelled = Task.isCancelled
            phase = .finished(summary)
            onRunningChange?(false)
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try await destination.prepare()
        } catch {
            summary.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        await source.prepareForImport()

        for item in items {
            if Task.isCancelled { break }
            var downloaded: [(file: MediaFile, url: URL)] = []
            var itemFailed = false
            let itemStartBytes = doneBytes
            for file in item.files {
                if Task.isCancelled { break }
                currentName = file.name
                let base = doneBytes
                guard let url = await fetch(file, from: source, base: base) else {
                    itemFailed = true
                    break
                }
                doneBytes = base + file.size
                downloaded.append((file, url))
            }
            if Task.isCancelled {
                downloaded.forEach { try? FileManager.default.removeItem(at: $0.url) }
                break
            }
            if !itemFailed {
                do {
                    let location = try await destination.store(item, files: downloaded)
                    ledger.record(item.files, location: location)
                    summary.imported += 1
                    summary.bytes += item.size
                    summary.location = location ?? summary.location
                    onItemImported?(item)
                } catch {
                    itemFailed = true
                    summary.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            if itemFailed {
                downloaded.forEach { try? FileManager.default.removeItem(at: $0.url) }
                summary.failed.append(item.primary.name)
                failedItems.append(item)
                doneBytes = itemStartBytes + item.size  // keep the bar moving
            }
            doneItems += 1
        }
    }

    /// Download one file (with retries) and check its size. Returns the temp URL.
    private func fetch(_ file: MediaFile, from source: any CameraSource, base: Int64) async -> URL? {
        for attempt in 0...retries {
            if Task.isCancelled { return nil }
            let url = tempDirectory.appendingPathComponent(UUID().uuidString + "-" + file.name)
            let reporter = ProgressReporter { [weak self] bytes in
                guard let self, isRunning else { return }
                doneBytes = max(doneBytes, min(base + bytes, base + file.size))  // late updates never move it back
            }
            do {
                let bytes = try await source.download(file, to: url) { reporter.report($0) }
                if file.size == 0 || bytes == file.size { return url }
            } catch {}
            try? FileManager.default.removeItem(at: url)
            if attempt < retries { try? await Task.sleep(for: .seconds(1)) }
        }
        return nil
    }
}

/// Forwards download progress to the main actor at most ~10 times a second.
final class ProgressReporter: @unchecked Sendable {
    private let update: @MainActor (Int64) -> Void
    private var last = Date.distantPast
    private let lock = NSLock()

    init(update: @escaping @MainActor (Int64) -> Void) {
        self.update = update
    }

    func report(_ bytes: Int64) {
        let now = Date()
        let send = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(last) > 0.1 else { return false }
            last = now
            return true
        }
        guard send else { return }
        Task { @MainActor in update(bytes) }
    }
}
