// Stage 0: how fast can the OM-3 transfer over a USB-C cable? Read-only.
//
//   swift tools/usb-speed/usb_speed.swift
//
// Connect the camera with a USB-C cable and turn it on. When the camera asks
// for a USB mode, try "Storage" first, then run again with "MTP".
// The tool copies the largest file (up to 300 MB) to a temporary folder,
// reports the speed, and deletes the copy. Nothing on the card is changed.

import Foundation
import ImageCaptureCore

let limit: Int64 = 300 * 1024 * 1024
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("om-usb-speed-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
func report(_ label: String, bytes: Int64, seconds: Double) {
    let speed = Double(bytes) / 1_000_000 / max(seconds, 0.001)
    print(String(format: "%@: %@ in %.1f s = %.1f MB/s  (Wi-Fi measured 3.1 MB/s, %.0fx)",
                 label, mb(bytes), seconds, speed, speed / 3.1))
}

// MARK: 1. Storage mode: the card appears as a disk.

func storageVolumes() -> [URL] {
    let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeNameKey]
    let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return vols.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DCIM").path) }
}

func testStorage(_ volume: URL) {
    print("Storage mode: found card at \(volume.path)")
    let dcim = volume.appendingPathComponent("DCIM")
    var files: [(URL, Int64)] = []
    let walker = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    while let url = walker?.nextObject() as? URL {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true, let size = v?.fileSize { files.append((url, Int64(size))) }
    }
    print("  \(files.count) file(s) under DCIM")
    guard let (src, size) = files.max(by: { $0.1 < $1.1 }) else { return }
    print("  copying \(src.lastPathComponent) (\(mb(size)), first \(mb(min(size, limit)))) ...")
    guard let input = FileHandle(forReadingAtPath: src.path) else { print("  cannot open"); return }
    let dst = tmp.appendingPathComponent(src.lastPathComponent)
    FileManager.default.createFile(atPath: dst.path, contents: nil)
    let output = FileHandle(forWritingAtPath: dst.path)!
    // Bypass the cache so we measure the cable, not RAM.
    _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
    var copied: Int64 = 0
    let t0 = Date()
    while copied < limit, let chunk = try? input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
        output.write(chunk)
        copied += Int64(chunk.count)
    }
    try? output.close()
    report("  Storage (USB disk)", bytes: copied, seconds: Date().timeIntervalSince(t0))
}

// MARK: 2. MTP / PTP mode: the camera appears to Image Capture.

final class Browser: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    var started = Date()
    var expected: Int64 = 0
    var done = false

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        print("Image Capture: found \(cam.name ?? "camera") (\(cam.transportType ?? "?"))")
        camera = cam
        cam.delegate = self
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { print("  cannot open session: \(error.localizedDescription)"); done = true }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let files = device.mediaFiles?.compactMap { $0 as? ICCameraFile } ?? []
        print("  \(files.count) file(s)")
        let small = files.filter { $0.fileSize <= limit }
        guard let file = small.max(by: { $0.fileSize < $1.fileSize }) ?? files.min(by: { $0.fileSize < $1.fileSize }) else {
            done = true
            return
        }
        expected = file.fileSize
        print("  downloading \(file.name ?? "?") (\(mb(file.fileSize))) ...")
        started = Date()
        device.requestDownloadFile(file, options: [.downloadsDirectoryURL: tmp, .overwrite: true],
                                   downloadDelegate: self,
                                   didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                                   contextInfo: nil)
    }

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        if let error {
            print("  download failed: \(error.localizedDescription)")
        } else {
            report("  MTP/PTP (Image Capture)", bytes: expected, seconds: Date().timeIntervalSince(started))
        }
        camera?.requestCloseSession()
        done = true
    }
}

// MARK: Run

defer { try? FileManager.default.removeItem(at: tmp) }
let volumes = storageVolumes()
if !volumes.isEmpty {
    volumes.forEach(testStorage)
} else {
    print("No card mounted as a disk; looking for the camera in Image Capture (20 s) ...")
    let b = Browser()
    b.start()
    let deadline = Date().addingTimeInterval(20)
    while !b.done {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if b.camera == nil, Date() > deadline {
            print("No camera found. Check the cable, turn the camera on, and pick a USB mode on the camera.")
            break
        }
    }
}
try? FileManager.default.removeItem(at: tmp)
