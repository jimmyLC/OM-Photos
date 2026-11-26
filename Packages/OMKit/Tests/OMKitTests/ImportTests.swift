import Foundation
import Testing
@testable import OMKit

/// A source backed by an in-memory card, with optional failures.
class MemorySource: CameraSource, @unchecked Sendable {
    var kind: SourceKind { .usb }
    var cacheKey: String { "memory" }
    var typicalSpeed: Double { 1_000_000 }
    var contents: [String: Data]
    var failuresLeft: [String: Int] = [:]
    var shortFiles: Set<String> = []
    var downloads: [String] = []
    var delay: Duration = .zero
    private let lock = NSLock()

    init(_ contents: [String: Data]) { self.contents = contents }

    func files() -> [MediaFile] {
        contents.keys.sorted().enumerated().map { i, path in
            MediaFile(path: path, size: Int64(contents[path]!.count), date: Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 60))
        }
    }

    func listFiles() async throws -> [MediaFile] { files() }
    func thumbnail(for file: MediaFile) async throws -> Data { Data() }
    func preview(for file: MediaFile) async throws -> Data { Data() }
    func movieInfo(for file: MediaFile) async throws -> MovieInfo { MovieInfo(duration: nil, resolution: nil) }
    func prepareForImport() async {}
    func details(files: [MediaFile]) async -> CameraDetails { CameraDetails() }
    var deleteFailures: Set<String> = []
    func delete(_ file: MediaFile) async throws {
        try lock.withLock {
            if deleteFailures.contains(file.name) { throw CameraError.http(status: 520, code: "1001") }
            contents[file.path] = nil
        }
    }

    func download(_ file: MediaFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        if delay > .zero { try await Task.sleep(for: delay) }
        let (data, fail) = lock.withLock { () -> (Data, Bool) in
            downloads.append(file.name)
            let left = failuresLeft[file.name, default: 0]
            if left > 0 { failuresLeft[file.name] = left - 1 }
            var d = contents[file.path]!
            if shortFiles.contains(file.name) { d = d.prefix(d.count / 2) }
            return (d, left > 0)
        }
        if fail { throw CameraError.unreachable("simulated") }
        try data.write(to: destination)
        progress(Int64(data.count))
        return Int64(data.count)
    }
}

@MainActor @Suite(.serialized)
struct ImportTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omkit-import-\(UUID())")

    func importer(_ ledger: ImportLedger) -> Importer {
        Importer(ledger: ledger, tempDirectory: tmp.appendingPathComponent("temp"))
    }

    func folder(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func flatFolderAndMissingFolder() async throws {
        let source = MemorySource(["/D/A.JPG": Data(count: 5), "/D/A.ORF": Data(count: 6)])
        let out = try folder("flat")
        let imp = importer(ImportLedger(url: nil))
        imp.start(MediaItem.group(source.files()), from: source, to: FolderDestination(root: out))
        _ = await waitDone(imp)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["A.JPG", "A.ORF"])

        let imp2 = importer(ImportLedger(url: nil))
        imp2.start(MediaItem.group(source.files()), from: source, to: FolderDestination(root: tmp.appendingPathComponent("nope")))
        let s = await waitDone(imp2)
        #expect(s.error?.contains("找不到資料夾") == true)
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("nope").path))  // never created
    }

    func waitDone(_ importer: Importer) async -> ImportSummary {
        for _ in 0..<500 {
            if case .finished(let s) = importer.phase { return s }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("import did not finish")
        return ImportSummary()
    }

    @Test func importsToDatedFoldersPhotosFirstAndRemembers() async throws {
        let source = MemorySource([
            "/DCIM/100OMSYS/A.MOV": Data(repeating: 1, count: 300),
            "/DCIM/100OMSYS/B.JPG": Data(repeating: 2, count: 100),
            "/DCIM/100OMSYS/B.ORF": Data(repeating: 3, count: 200),
            "/DCIM/100OMSYS/C.JPG": Data(repeating: 4, count: 50),
        ])
        let root = tmp.appendingPathComponent("out")
        let ledgerURL = tmp.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ledger = ImportLedger(url: ledgerURL)
        let imp = importer(ledger)
        var running: [Bool] = []
        imp.onRunningChange = { running.append($0) }
        let items = MediaItem.group(source.files())

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        imp.start(items, from: source, to: FolderDestination(root: root, daySubfolders: true))
        let s = await waitDone(imp)
        #expect(s.imported == 3)
        #expect(s.failed.isEmpty)
        #expect(running == [true, false])
        #expect(source.downloads.last == "A.MOV")  // video last
        let day = FolderDestination.dayName(source.files()[0].date)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(day).path).sorted()
        #expect(names == ["A.MOV", "B.JPG", "B.ORF", "C.JPG"])
        #expect(imp.fraction == 1)

        // A new ledger instance reads the saved file: nothing is new any more.
        let reopened = ImportLedger(url: ledgerURL)
        #expect(imp.newItems(items).isEmpty)
        #expect(reopened.importedIDs(in: items).count == 3)
        // Moving the copies away does not make them new again.
        try FileManager.default.removeItem(at: root)
        #expect(reopened.importedIDs(in: items).count == 3)
    }

    @Test func retriesOnceThenReportsFailure() async throws {
        let source = MemorySource(["/D/A.JPG": Data(count: 10), "/D/B.JPG": Data(count: 10), "/D/C.JPG": Data(count: 10)])
        source.failuresLeft = ["A.JPG": 1, "B.JPG": 5]  // A recovers on retry, B never does
        source.shortFiles = ["C.JPG"]  // size mismatch counts as failure
        let ledger = ImportLedger(url: nil)
        let imp = importer(ledger)
        let items = MediaItem.group(source.files())
        imp.start(items, from: source, to: FolderDestination(root: try folder("out2")))
        let s = await waitDone(imp)
        #expect(s.imported == 1)
        #expect(Set(s.failed) == ["B.JPG", "C.JPG"])
        #expect(Set(imp.failedItems.map(\.primary.name)) == ["B.JPG", "C.JPG"])
        #expect(!ledger.isImported(items.first { $0.primary.name == "B.JPG" }!))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("temp").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func neverOverwritesADifferentFile() async throws {
        let source = MemorySource(["/D/A.JPG": Data(repeating: 9, count: 20)])
        let file = source.files()[0]
        let dayFolder = tmp.appendingPathComponent("out3").appendingPathComponent(FolderDestination.dayName(file.date))
        try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: dayFolder.appendingPathComponent("A.JPG"))
        let imp = importer(ImportLedger(url: nil))
        imp.start(MediaItem.group([file]), from: source, to: FolderDestination(root: tmp.appendingPathComponent("out3"), daySubfolders: true))
        _ = await waitDone(imp)
        #expect(try String(contentsOf: dayFolder.appendingPathComponent("A.JPG"), encoding: .utf8) == "other")
        #expect(try Data(contentsOf: dayFolder.appendingPathComponent("A (1).JPG")).count == 20)
    }

    @Test func cancelStopsEarly() async throws {
        let source = MemorySource(Dictionary(uniqueKeysWithValues: (1...20).map { ("/D/P\($0).JPG", Data(count: 10)) }))
        source.delay = .milliseconds(30)
        let ledger = ImportLedger(url: nil)
        let imp = importer(ledger)
        imp.start(MediaItem.group(source.files()), from: source, to: FolderDestination(root: try folder("out4")))
        try await Task.sleep(for: .milliseconds(100))
        imp.cancel()
        let s = await waitDone(imp)
        #expect(s.cancelled)
        #expect(s.imported < 20)
        #expect(ledger.count == s.imported)
    }

    @Test func usbCopy() async throws {
        let root = tmp.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("DCIM/100OMSYS"), withIntermediateDirectories: true)
        let payload = Data((0..<9_000_000).map { UInt8($0 % 251) })
        try payload.write(to: root.appendingPathComponent("DCIM/100OMSYS/V.MOV"))
        let source = VolumeSource(root: root)
        let file = try await source.listFiles()[0]
        let out = tmp.appendingPathComponent("v.mov")
        let progress = ProgressBox()
        let n = try await source.download(file, to: out) { progress.add($0) }
        #expect(n == 9_000_000)
        #expect(try Data(contentsOf: out) == payload)
        #expect(progress.calls >= 2)  // 4 MB chunks
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_: Int64) { lock.withLock { count += 1 } }
    var calls: Int { lock.withLock { count } }
}

@MainActor @Suite(.serialized)
struct DeleteTests {
    @Test func deletesWholeItemsSkipsProtectedReportsFailures() async {
        let source = ProtectedSource([
            "/D/A.JPG": Data(count: 1), "/D/A.ORF": Data(count: 1),
            "/D/B.JPG": Data(count: 1), "/D/C.JPG": Data(count: 1), "/D/L.JPG": Data(count: 1),
        ])
        source.protectedNames = ["L.JPG"]
        source.deleteFailures = ["C.JPG"]
        let library = LibraryModel(images: ImageStore(directory: nil))
        await library.setSource(source)
        library.selectAll()
        let result = await library.delete(library.selectedItems)
        #expect(result.deleted == 2)
        #expect(result.failed == ["C.JPG"])
        #expect(result.skippedProtected == 1)
        #expect(Set(source.contents.keys) == ["/D/C.JPG", "/D/L.JPG"])  // A.JPG and A.ORF both gone
        #expect(Set(library.items.map(\.primary.name)) == ["C.JPG", "L.JPG"])  // list reloaded
        #expect(library.selection.isEmpty)
    }

    @Test func usbDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omkit-del-\(UUID())")
        let dir = root.appendingPathComponent("DCIM/100OMSYS")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("P1.JPG"))
        let source = VolumeSource(root: root)
        try await source.delete(try await source.listFiles()[0])
        #expect(try await source.listFiles().isEmpty)
    }
}

final class ProtectedSource: MemorySource, @unchecked Sendable {
    var protectedNames: Set<String> = []
    override func files() -> [MediaFile] {
        super.files().map { var f = $0; f.isProtected = protectedNames.contains(f.name); return f }
    }
}

/// Tests that use the shared FakeCard run in SourceTests' serialized suite.
extension SourceTests {
    @Test func wifiDownloadStreamsAndChecksStatus() async throws {
        FakeCard.lock.withLock {
            FakeCard.listing = [:]
            FakeCard.jpeg = Data(repeating: 7, count: 123_456)
        }
        let client = CameraClient(session: FakeCard.session())
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("omkit-dl-\(UUID()).bin")
        // FakeCard serves JPEG bytes for get_thumbnail; use that path to exercise streaming.
        let n = try await client.download("/get_thumbnail.cgi", to: dest) { _ in }
        #expect(n == 123_456)
        #expect(try Data(contentsOf: dest).count == 123_456)
        await #expect(throws: CameraError.self) {
            _ = try await client.download("/get_imglist.cgi", to: dest) { _ in }  // 404 here
        }
    }

    @Test func wifiErase() async throws {
        FakeCard.lock.withLock { FakeCard.hits = []; FakeCard.listing = [:] }
        let source = WiFiSource(client: CameraClient(session: FakeCard.session()), cameraID: "D", settle: .zero)
        try await source.delete(MediaFile(path: "/DCIM/100OMSYS/P1.JPG", size: 1, date: .now))
        #expect(FakeCard.hits.contains("/exec_erase.cgi?DIR=/DCIM/100OMSYS/P1.JPG"))
    }
}

@MainActor @Suite(.serialized)
struct DragSelectTests {
    func library() async -> LibraryModel {
        let source = MemorySource(Dictionary(uniqueKeysWithValues: (1...6).map { ("/D/P\($0).JPG", Data(count: 1)) }))
        let library = LibraryModel(images: ImageStore(directory: nil))
        await library.setSource(source)
        return library
    }

    @Test func dragAddsRangeAndShrinksBack() async {
        let l = await library()
        let ids = l.filtered.map(\.id)
        l.dragSelect(from: ids[1], to: ids[4], base: [ids[0]], deselect: false)
        #expect(l.selection == Set(ids[0...4]))
        l.dragSelect(from: ids[1], to: ids[2], base: [ids[0]], deselect: false)  // finger moved back
        #expect(l.selection == Set(ids[0...2]))
        l.dragSelect(from: ids[3], to: ids[1], base: [], deselect: false)  // backwards
        #expect(l.selection == Set(ids[1...3]))
    }

    @Test func dragFromSelectedItemDeselects() async {
        let l = await library()
        let ids = l.filtered.map(\.id)
        l.dragSelect(from: ids[1], to: ids[2], base: Set(ids), deselect: true)
        #expect(l.selection == Set(ids).subtracting([ids[1], ids[2]]))
    }

    @Test func quietReloadKeepsListOnError() async {
        let l = await library()
        let source = l.source as! MemorySource
        source.contents = [:]
        await l.reload(quietly: true)
        #expect(l.phase == .loaded)
        #expect(l.items.isEmpty)
    }
}
