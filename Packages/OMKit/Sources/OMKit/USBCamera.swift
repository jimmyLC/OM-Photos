import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ImageCaptureCore
import Observation

/// Finds a camera plugged in with a cable (USB mode "MTP"; on iPhone and iPad also
/// "Storage") through the system's Image Capture framework, and opens it.
@MainActor @Observable
public final class USBCameraMonitor: NSObject {
    /// The camera ready to use, or nil when none is plugged in.
    public private(set) var source: USBCameraSource?
    /// A problem worth telling the user (permission refused, camera busy…).
    public var problem: String?

    private var browser: ICDeviceBrowser?
    private var session: USBCameraSession?

    public override init() {
        super.init()
    }

    /// Begin watching. Safe to call more than once. On iPhone and iPad the first call
    /// asks for permission to read and control an attached camera.
    public func start() {
        #if targetEnvironment(simulator)
        // The simulator has no cameras, and its framework lacks the permission calls.
        return
        #else
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        self.browser = browser
        #if os(macOS)
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        #else
        // The answers arrive on a background queue: the closures must not be main-actor
        // isolated (that would trap), so they are @Sendable and hop over themselves.
        browser.requestContentsAuthorization { @Sendable [weak self] status in
            let granted = status == .authorized
            Task { @MainActor in self?.contentsAuthorization(granted: granted) }
        }
        #endif
        #endif
    }

    #if os(iOS)
    private func contentsAuthorization(granted: Bool) {
        guard let browser else { return }
        guard granted else {
            problem = "沒有讀取外接相機的權限。請到 設定 › OM Photos 允許。"
            return
        }
        // Control permission is needed for deleting.
        browser.requestControlAuthorization { @Sendable [weak self] _ in
            Task { @MainActor in self?.browser?.start() }
        }
    }
    #endif

    /// Cameras on a cable. On the Mac a card in Storage mode is handled as a disk
    /// instead, so only real PTP/MTP cameras count there.
    private func accepts(_ device: ICDevice) -> Bool {
        guard device is ICCameraDevice else { return false }
        let transport = device.transportType
        #if os(macOS)
        return transport == ICDeviceTransport.transportTypeUSB.rawValue
        #else
        return transport != ICDeviceTransport.transportTypeTCPIP.rawValue
        #endif
    }

    private func added(_ camera: ICCameraDevice) {
        guard session == nil, accepts(camera) else { return }
        let session = USBCameraSession(camera: camera)
        session.onFailure = { [weak self] message in
            self?.problem = message
            self?.removed(camera)
        }
        self.session = session
        source = USBCameraSource(session: session)
        session.open()
    }

    private func removed(_ device: ICDevice) {
        guard let session, session.camera === device else { return }
        session.close()
        self.session = nil
        source = nil
    }
}

extension USBCameraMonitor: ICDeviceBrowserDelegate {
    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            if let camera = device as? ICCameraDevice { added(camera) }
        }
    }

    nonisolated public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated { removed(device) }
    }
}

// MARK: - Session

/// One open camera. Image Capture calls its delegate on the main thread.
@MainActor
final class USBCameraSession: NSObject {
    let camera: ICCameraDevice
    var onFailure: ((String) -> Void)?
    private var ready = false
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var files: [String: ICCameraFile] = [:]
    private var deleted: Set<String> = []

    init(camera: ICCameraDevice) {
        self.camera = camera
        super.init()
    }

    func open() {
        camera.delegate = self
        camera.requestOpenSession()
    }

    func close() {
        closed = true
        finish(.failure(CameraError.unreachable("相機已拔除")))
        camera.delegate = nil
        if camera.hasOpenSession { camera.requestCloseSession() }
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(with: result) }
    }

    /// The camera lists its files after the session opens; this can take a while.
    func waitUntilReady() async throws {
        if closed { throw CameraError.unreachable("相機已拔除") }
        if ready { return }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func list() async throws -> [MediaFile] {
        try await waitUntilReady()
        var map: [String: ICCameraFile] = [:]
        var out: [MediaFile] = []
        for case let file as ICCameraFile in camera.mediaFiles ?? [] {
            guard let name = file.name else { continue }
            let path = Self.cardPath(name: name, parents: Self.parents(of: file))
            guard !deleted.contains(path), FileKind.of(name) != .other else { continue }
            map[path] = file
            out.append(MediaFile(path: path, size: Int64(file.fileSize),
                                 date: file.creationDate ?? file.modificationDate ?? .distantPast,
                                 isProtected: file.isLocked))
        }
        files = map
        return out
    }

    private static func parents(of file: ICCameraItem) -> [String] {
        var names: [String] = []
        var folder = file.parentFolder
        while let f = folder {
            names.insert(f.name ?? "", at: 0)
            folder = f.parentFolder
        }
        return names
    }

    /// The same "/DCIM/100OMSYS/NAME" path the card has over Wi-Fi and as a disk, so
    /// the import history is shared between all three.
    nonisolated static func cardPath(name: String, parents: [String]) -> String {
        var folders = parents.filter { !$0.isEmpty }
        if let dcim = folders.firstIndex(where: { $0.uppercased() == "DCIM" }) {
            folders = Array(folders[dcim...])
        }
        return "/" + (folders + [name]).joined(separator: "/")
    }

    func file(_ media: MediaFile) throws -> ICCameraFile {
        guard !closed, let file = files[media.path] else {
            throw CameraError.unreachable("相機上找不到 \(media.name)")
        }
        return file
    }

    func delete(_ media: MediaFile) async throws {
        let target = try file(media)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            _ = camera.requestDeleteFiles([target], deleteFailed: { @Sendable _ in }, completion: { @Sendable result, error in
                if let error {
                    c.resume(throwing: error)
                } else if result[.failed]?.isEmpty == false {
                    c.resume(throwing: CameraError.badResponse("相機拒絕刪除"))
                } else {
                    c.resume()
                }
            })
        }
        deleted.insert(media.path)
        files[media.path] = nil
    }
}

extension USBCameraSession: ICCameraDeviceDelegate {
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated {
            ready = true
            finish(.success(()))
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard let message else { return }
            finish(.failure(CameraError.unreachable(message)))
            onFailure?("無法開啟 USB 相機：\(message)")
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated { finish(.failure(CameraError.unreachable("相機已拔除"))) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - Source

public struct USBCameraSource: CameraSource {
    let session: USBCameraSession
    public let cacheKey: String
    public let name: String
    public var kind: SourceKind { .usbCamera }
    public var typicalSpeed: Double { 30_000_000 }  // measured 34.6 MB/s on a Mac in MTP mode

    @MainActor
    init(session: USBCameraSession) {
        self.session = session
        name = session.camera.name ?? "USB 相機"
        cacheKey = "ptp-" + (session.camera.uuidString ?? session.camera.name ?? "camera")
    }

    public func listFiles() async throws -> [MediaFile] {
        try await session.list()
    }

    public func thumbnail(for file: MediaFile) async throws -> Data {
        try await thumbnailData(file, maxPixels: 480)
    }

    public func preview(for file: MediaFile) async throws -> Data {
        let data = try await thumbnailData(file, maxPixels: 2400)
        if file.kind == .movie || Self.longSide(data) >= 1200 { return data }
        // The camera only offered a small picture: fetch the photo itself.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + file.name)
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await download(file, to: temp) { _ in }
        guard let source = CGImageSourceCreateWithURL(temp as CFURL, nil),
              let image = Imaging.downsample(source, maxPixels: 2400) else { return data }
        return try Imaging.jpegData(image)
    }

    public func movieInfo(for file: MediaFile) async throws -> MovieInfo {
        let item = try await session.file(file)
        return await MainActor.run {
            MovieInfo(duration: item.duration > 0 ? item.duration : nil,
                      resolution: item.width > 0 ? "\(item.width)x\(item.height)" : nil)
        }
    }

    public func prepareForImport() async {}

    public func download(_ file: MediaFile, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let item = try await session.file(file)
        let handle = DownloadHandle()
        let size = file.size
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let options: [ICDownloadOption: Any] = [
                    .downloadsDirectoryURL: destination.deletingLastPathComponent(),
                    .saveAsFilename: destination.lastPathComponent,
                    .overwrite: true,
                ]
                let running = item.requestDownload(options: options) { _, error in
                    handle.finish()
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
                if let running {
                    handle.watch(running) { fraction in progress(Int64(fraction * Double(size))) }
                }
            }
        } onCancel: {
            handle.cancel()
        }
        try Task.checkCancellation()
        let written = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        progress(Int64(written))
        return Int64(written)
    }

    public func delete(_ file: MediaFile) async throws {
        try await session.delete(file)
    }

    public func details(files: [MediaFile]) async -> CameraDetails {
        var d = CameraDetails()
        d.model = name
        d.fileCount = files.count
        #if os(macOS)
        d.battery = await MainActor.run {
            session.camera.batteryLevelAvailable ? Int(session.camera.batteryLevel) : nil
        }
        #endif
        if let candidate = CameraDetails.exifCandidate(files), let item = try? await session.file(candidate),
           let data = try? await Self.read(item, length: min(Int(candidate.size), 256 * 1024)) {
            d.readEXIF(CGImageSourceCreateWithData(data as CFData, nil))
        }
        return d
    }

    private func thumbnailData(_ file: MediaFile, maxPixels: Int) async throws -> Data {
        let item = try await session.file(file)
        return try await withCheckedThrowingContinuation { c in
            item.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixels]) { data, error in
                if let data {
                    c.resume(returning: data)
                } else {
                    c.resume(throwing: error ?? CameraError.badResponse("沒有縮圖"))
                }
            }
        }
    }

    private static func read(_ item: ICCameraFile, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            item.requestReadData(atOffset: 0, length: off_t(length)) { data, error in
                if let data {
                    c.resume(returning: data)
                } else {
                    c.resume(throwing: error ?? CameraError.badResponse("讀取失敗"))
                }
            }
        }
    }

    static func longSide(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return max(p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

/// Progress and cancellation of one Image Capture download.
private final class DownloadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func watch(_ progress: Progress, report: @escaping @Sendable (Double) -> Void) {
        let observation = progress.observe(\.fractionCompleted) { p, _ in report(p.fractionCompleted) }
        let cancelNow = lock.withLock {
            self.progress = progress
            self.observation = observation
            return cancelled
        }
        if cancelNow { progress.cancel() }
    }

    func cancel() {
        let running = lock.withLock {
            cancelled = true
            return progress
        }
        running?.cancel()
    }

    func finish() {
        lock.withLock {
            observation = nil
            progress = nil
        }
    }
}
