import AppKit
import OMKit

/// Watches for camera cards mounted over USB (camera USB mode "Storage").
@MainActor
final class VolumeWatcher {
    private var observers: [NSObjectProtocol] = []
    private let onChange: ([URL]) -> Void

    init(onChange: @escaping ([URL]) -> Void) {
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scan() }
            })
        }
        scan()
    }

    func scan() {
        onChange(Self.currentCards())
    }

    /// Camera cards mounted right now.
    nonisolated static func currentCards() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let external = v?.volumeIsRemovable == true || v?.volumeIsEjectable == true || url.path.hasPrefix("/Volumes/")
            return external && VolumeSource.looksLikeCard(url)
        }
    }
}
