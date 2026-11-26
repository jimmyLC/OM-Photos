import Testing
@testable import OMKit

struct USBCameraTests {
    @Test func cardPathMatchesWiFiAndDiskPaths() {
        let expected = "/DCIM/100OMSYS/PB260003.JPG"
        #expect(USBCameraSession.cardPath(name: "PB260003.JPG", parents: ["DCIM", "100OMSYS"]) == expected)
        #expect(USBCameraSession.cardPath(name: "PB260003.JPG", parents: ["OM SYSTEM", "DCIM", "100OMSYS"]) == expected)
        #expect(USBCameraSession.cardPath(name: "PB260003.JPG", parents: ["", "DCIM", "100OMSYS"]) == expected)
        #expect(USBCameraSession.cardPath(name: "A.JPG", parents: []) == "/A.JPG")
    }
}
