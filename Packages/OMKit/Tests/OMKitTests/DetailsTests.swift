import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMKit

struct DetailsTests {
    func jpegWithEXIF(software: String) -> Data {
        let image = CIContext().createCGImage(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
                                              from: CGRect(x: 0, y: 0, width: 8, height: 8))!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "OM-3  ", kCGImagePropertyTIFFSoftware: software],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "OLYMPUS M.17mm F1.8"],
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func readsModelFirmwareAndLens() {
        var d = CameraDetails()
        d.readEXIF(CGImageSourceCreateWithData(jpegWithEXIF(software: "Version 1.1          ") as CFData, nil))
        #expect(d.model == "OM-3")
        #expect(d.firmware == "1.1")
        #expect(d.lens == "OLYMPUS M.17mm F1.8")
    }

    @Test func ignoresEditorSoftwareName() {
        var d = CameraDetails()
        d.readEXIF(CGImageSourceCreateWithData(jpegWithEXIF(software: "Photos 11.0") as CFData, nil))
        #expect(d.firmware == nil)
    }

    @Test func prefersNewestJPG() {
        let f = { (n: String, t: Double) in MediaFile(path: "/D/\(n)", size: 1, date: Date(timeIntervalSince1970: t)) }
        #expect(CameraDetails.exifCandidate([f("a.JPG", 1), f("b.ORF", 3), f("c.JPG", 2), f("d.MOV", 4)])?.name == "c.JPG")
        #expect(CameraDetails.exifCandidate([f("b.ORF", 3), f("d.MOV", 4)])?.name == "b.ORF")
    }

    @Test func usbDetails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omkit-det-\(UUID())")
        let dir = root.appendingPathComponent("DCIM/100OMSYS")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpegWithEXIF(software: "Version 1.2").write(to: dir.appendingPathComponent("P1.JPG"))
        defer { try? FileManager.default.removeItem(at: root) }
        let source = VolumeSource(root: root)
        let d = await source.details(files: try await source.listFiles())
        #expect(d.fileCount == 1)
        #expect(d.firmware == "1.2")
        #expect((d.capacity ?? 0) > 0)
    }
}
