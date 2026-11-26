import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMKit

struct MediaTests {
    func f(_ path: String, _ size: Int64 = 10, _ minute: Int = 0, protected: Bool = false) -> MediaFile {
        MediaFile(path: path, size: size, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60), isProtected: protected)
    }

    @Test func groupsRawWithJpg() {
        let items = MediaItem.group([
            f("/DCIM/100OMSYS/P1.JPG", 10, 1), f("/DCIM/100OMSYS/P1.ORF", 20, 1),
            f("/DCIM/100OMSYS/P2.ORF", 20, 2), f("/DCIM/100OMSYS/P3.MOV", 99, 3),
            f("/DCIM/100OMSYS/P4.JPG", 10, 4), f("/DCIM/101OMSYS/P1.JPG", 10, 5),
            f("/DCIM/100OMSYS/notes.TXT"),
        ])
        #expect(items.map(\.badge) == ["JPG", "JPG", "MOV", "RAW", "RAW+JPG"])  // newest first
        let pair = items.last!
        #expect(pair.primary.kind == .jpg)
        #expect(pair.size == 30)
        #expect(items[0].id == "/DCIM/101OMSYS/P1")  // same stem, other folder: separate
    }

    @Test func movieWithSameStemAsPhotoStaysSeparate() {
        let items = MediaItem.group([f("/DCIM/100OMSYS/P1.JPG"), f("/DCIM/100OMSYS/P1.MP4")])
        #expect(items.count == 2)
        #expect(Set(items.map(\.badge)) == ["JPG", "MP4"])
    }

    @Test func filters() {
        let items = MediaItem.group([f("/D/a.JPG"), f("/D/b.JPG"), f("/D/b.ORF"), f("/D/c.ORF"), f("/D/d.MOV")])
        #expect(items.filter(TypeFilter.photos.matches).count == 3)
        #expect(items.filter(TypeFilter.raw.matches).count == 2)
        #expect(items.filter(TypeFilter.videos.matches).count == 1)
    }

    @Test func parsesCameraListing() {
        let text = "VER_100\r\n/DCIM/100OMSYS,PB260003.JPG,10971984,0,23930,33725\r\n/DCIM,100OMSYS,0,16,23929,25171\r\n/DCIM/100OMSYS,LOCK.JPG,5,1,23930,33725\r\n"
        let rows = ListEntry.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0].file.path == "/DCIM/100OMSYS/PB260003.JPG")
        #expect(rows[0].file.size == 10971984)
        #expect(rows[1].isDirectory)
        #expect(rows[2].file.isProtected)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rows[0].file.date)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 11, 26, 16, 29, 58])
    }

    @Test func daySections() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let d1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 23))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 1))!
        let d3 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 23))!
        let items = [d1, d2, d3].enumerated().map { MediaItem(files: [MediaFile(path: "/D/\($0.offset).JPG", size: 1, date: $0.element)]) }
        let s = Days.sections(items, calendar: cal)
        #expect(s.map(\.items.count) == [2, 1])
        #expect(Days.title(s[0].day, now: d1, calendar: cal) == "今天")
        #expect(Days.title(s[1].day, now: d1, calendar: cal) == "昨天")
    }

    @Test func durationText() {
        #expect(MovieInfo(duration: 4, resolution: nil).durationText == "0:04")
        #expect(MovieInfo(duration: 3725, resolution: nil).durationText == "1:02:05")
    }
}

/// A fake camera that serves a listing, thumbnails and movie info.
final class FakeCard: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var listing: [String: String] = [:]
    nonisolated(unsafe) static var hits: [String] = []
    nonisolated(unsafe) static var jpeg = Data()
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeCard.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let dir = url.query?.components(separatedBy: "DIR=").last?.components(separatedBy: "&").first ?? ""
        let (listing, jpeg) = Self.lock.withLock { () -> ([String: String], Data) in
            Self.hits.append(url.path + "?" + (url.query ?? ""))
            return (Self.listing, Self.jpeg)
        }
        var status = 200
        var body = Data()
        switch url.path {
        case "/get_imglist.cgi":
            if let text = listing[dir] { body = Data(text.utf8) } else { status = 404 }
        case "/get_thumbnail.cgi", "/get_screennail.cgi": body = jpeg
        case "/get_movfileinfo.cgi": body = Data("<response><playtime>4</playtime><moviesize>3840x2160</moviesize></response>".utf8)
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func makeJPEG(width: Int = 64, height: Int = 48) -> Data {
    let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let cg = CIContext().createCGImage(image, from: image.extent)!
    return try! Imaging.jpegData(cg)
}

@MainActor @Suite(.serialized)
struct SourceTests {
    @Test func wifiListingThumbnailAndCache() async throws {
        FakeCard.lock.withLock {
            FakeCard.listing = [
                "/DCIM": "VER_100\r\n/DCIM,100OMSYS,0,16,23929,25171\r\n",
                "/DCIM/100OMSYS": "VER_100\r\n/DCIM/100OMSYS,P1.JPG,100,0,23930,33725\r\n/DCIM/100OMSYS,P1.ORF,200,0,23930,33725\r\n/DCIM/100OMSYS,P2.MOV,300,0,23930,33800\r\n",
            ]
            FakeCard.hits = []
            FakeCard.jpeg = makeJPEG()
        }
        let source = WiFiSource(client: CameraClient(session: FakeCard.session()), cameraID: "TEST", settle: .zero)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omkit-cache-\(UUID())")
        let library = LibraryModel(images: ImageStore(directory: dir))
        await library.setSource(source)
        #expect(library.phase == .loaded)
        #expect(library.items.map(\.badge) == ["MOV", "RAW+JPG"])
        #expect(FakeCard.hits.first == "/switch_cammode.cgi?mode=play")

        let photo = library.items[1]
        #expect(await library.thumbnail(for: photo)?.width == 64)
        #expect(FakeCard.hits.contains("/get_thumbnail.cgi?DIR=/DCIM/100OMSYS/P1.JPG"))  // JPG, not the RAW

        // A fresh store with the same disk cache does not ask the camera again.
        FakeCard.lock.withLock { FakeCard.hits = [] }
        let again = LibraryModel(images: ImageStore(directory: dir))
        await again.setSource(source)
        _ = await again.thumbnail(for: again.items[1])
        #expect(!FakeCard.hits.contains { $0.hasPrefix("/get_thumbnail") })

        await library.loadMovieInfo(for: library.items[0])
        #expect(library.movieInfo[library.items[0].id]?.durationText == "0:04")
        #expect(library.movieInfo[library.items[0].id]?.resolution == "3840x2160")
    }

    @Test func wifiEmptyCard() async {
        FakeCard.lock.withLock { FakeCard.listing = [:] }
        let library = LibraryModel(images: ImageStore(directory: nil))
        await library.setSource(WiFiSource(client: CameraClient(session: FakeCard.session()), cameraID: "E", settle: .zero))
        #expect(library.phase == .loaded)
        #expect(library.items.isEmpty)
    }

    @Test func usbVolume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omkit-card-\(UUID())")
        let folder = root.appendingPathComponent("DCIM/100OMSYS")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try makeJPEG(width: 1200, height: 900).write(to: folder.appendingPathComponent("PB010001.JPG"))
        try Data("raw".utf8).write(to: folder.appendingPathComponent("PB010001.ORF"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".hidden.JPG"))
        try Data("x".utf8).write(to: root.appendingPathComponent("DCIM/README.TXT"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(VolumeSource.looksLikeCard(root))
        #expect(!VolumeSource.looksLikeCard(folder))
        let library = LibraryModel(images: ImageStore(directory: nil))
        await library.setSource(VolumeSource(root: root))
        #expect(library.items.count == 1)
        #expect(library.items[0].badge == "RAW+JPG")
        #expect(library.items[0].files.map(\.path) == ["/DCIM/100OMSYS/PB010001.JPG", "/DCIM/100OMSYS/PB010001.ORF"])
        let thumb = await library.thumbnail(for: library.items[0])
        #expect(thumb.map { max($0.width, $0.height) } == 480)
    }

    @Test func selection() async {
        let library = LibraryModel(images: ImageStore(directory: nil))
        FakeCard.lock.withLock {
            FakeCard.listing = ["/DCIM": "/DCIM,100OMSYS,0,16,1,1\r\n",
                                "/DCIM/100OMSYS": (1...5).map { "/DCIM/100OMSYS,P\($0).JPG,10,0,23930,\(33000 + $0)\r\n" }.joined()]
        }
        await library.setSource(WiFiSource(client: CameraClient(session: FakeCard.session()), cameraID: "S", settle: .zero))
        let list = library.filtered
        library.select(list[1], extend: false, toggle: false)
        library.select(list[3], extend: true, toggle: false)
        #expect(library.selection == Set(list[1...3].map(\.id)))
        library.select(list[2], extend: false, toggle: true)
        #expect(library.selection.count == 2)
        library.selectAll()
        #expect(library.selection.count == 5)
        #expect(library.selectedSize == 50)
    }
}
