import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import OMKit

struct PairingCodeTests {
    let sample = CameraCredentials(ssid: "OM-3-P-TEST12345", password: "1234567890123456",
                                   bluetoothName: "TEST12345", bluetoothPasscode: "123456")

    func ois3(_ c: CameraCredentials) -> String {
        "OIS3,1,0," + [c.ssid, c.password, c.bluetoothName, c.bluetoothPasscode].map(PairingCode.encode).joined(separator: ",")
    }

    @Test func decodesOIS3() {
        let raw = ois3(sample)
        #expect(raw != "OIS3,1,0,OM-3-P-TEST12345,1234567890123456,TEST12345,123456")  // really obfuscated
        #expect(PairingCode.parse(raw) == sample)
    }

    @Test func decodesOIS1() {
        let raw = "OIS1,\(PairingCode.encode("E-M10MKII-P-1")),\(PairingCode.encode("PASS1234"))"
        #expect(PairingCode.parse(raw) == CameraCredentials(ssid: "E-M10MKII-P-1", password: "PASS1234"))
    }

    @Test func mappingIsItsOwnInverse() {
        let all = String(PairingCode.table)
        #expect(PairingCode.decode(PairingCode.encode(all)) == all)
        #expect(PairingCode.decode("abc_") == "abc_")  // outside the table: unchanged
    }

    @Test func rejectsOtherCodes() {
        #expect(PairingCode.parse("WIFI:S:home;T:WPA;P:secret;;") == nil)
        #expect(PairingCode.parse("OIS3,1,0") == nil)
        #expect(PairingCode.parse("OIS1,,x") == nil)
        #expect(PairingCode.parse("") == nil)
    }

    @Test func readsQRFromImage() throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(ois3(sample).utf8)
        let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        #expect(QRImageReader.credentials(in: image) == sample)
    }

    @Test func defaultName() {
        #expect(PairedCamera.defaultName(for: "OM-3-P-TEST00000") == "OM-3")
        #expect(PairedCamera.defaultName(for: "MyCam") == "MyCam")
    }
}

/// The real keychain needs app entitlements, so it is tested on device; here we check
/// the store contract with the in-memory version.
struct StoreTests {
    @Test func saveReplaceDelete() throws {
        let store = MemoryCameraStore()
        let a = PairedCamera(name: "OM-3", credentials: .init(ssid: "A", password: "1"), pairedAt: .distantPast)
        try store.save(a)
        try store.save(PairedCamera(name: "OM-3", credentials: .init(ssid: "A", password: "2")))
        #expect(try store.all().count == 1)
        #expect(try store.all().first?.credentials.password == "2")
        try store.delete(ssid: "A")
        #expect(try store.all().isEmpty)
    }
}
