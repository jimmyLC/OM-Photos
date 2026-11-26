import Foundation
import Observation
import OMKit

/// Where the library reads from.
enum SourceID: Hashable {
    case wifi
    case volume(URL)
}

/// Sidebar rows (one selection, like the Photos sidebar).
enum SidebarItem: Hashable {
    case source(SourceID)
    case type(TypeFilter)
    case day(Date)
}

/// App-wide state shared by every window and platform.
@MainActor @Observable
final class AppModel {
    let connection: ConnectionManager
    let library = LibraryModel()

    /// Camera cards available over USB (camera in "Storage" mode).
    private(set) var volumes: [URL] = []
    var selectedSource: SourceID = .wifi
    /// Day the grid should scroll to (set from the sidebar or the date menu).
    var scrollTarget: Date?
    /// Item open in the full-screen viewer.
    var viewing: MediaItem.ID?
    /// iPhone/iPad: taps select instead of opening the viewer.
    var selecting = false
    /// iPhone/iPad: show the Files picker to choose the USB card.
    var pickingVolume = false

    init(connection: ConnectionManager) {
        self.connection = connection
        connection.powerOffWhenDone = UserDefaults.standard.object(forKey: SettingKey.powerOffWhenDone) as? Bool ?? true
    }

    var sourceTitle: String {
        switch selectedSource {
        case .wifi: connection.current?.name ?? connection.cameras.first?.name ?? "相機"
        case .volume(let url): VolumeSource(root: url).displayName
        }
    }

    /// Call when the connection or the selected source changes.
    func syncSource() async {
        switch selectedSource {
        case .wifi:
            if connection.isConnected, let camera = connection.current {
                await library.setSource(WiFiSource(client: connection.client, cameraID: camera.id))
            } else {
                await library.setSource(nil)
            }
        case .volume(let url):
            await library.setSource(VolumeSource(root: url))
        }
    }

    func select(_ source: SourceID) async {
        selectedSource = source
        library.typeFilter = .all
        await syncSource()
    }

    // MARK: USB

    /// Replace the list of mounted cards (from the Mac volume watcher).
    func setVolumes(_ urls: [URL]) async {
        let added = urls.filter { !volumes.contains($0) }
        volumes = urls
        if case .volume(let current) = selectedSource, !urls.contains(current) {
            selectedSource = .wifi
            await syncSource()
        } else if let first = added.first, !(selectedSource == .wifi && connection.isConnected) {
            // A card was plugged in: show it (faster than Wi-Fi), unless Wi-Fi is in use.
            await select(.volume(first))
        }
    }

    /// iOS/iPadOS: the user picked the card folder in the Files picker.
    func addPickedVolume(_ url: URL) async -> Bool {
        _ = url.startAccessingSecurityScopedResource()  // kept for the whole session
        guard VolumeSource.looksLikeCard(url) else {
            url.stopAccessingSecurityScopedResource()
            return false
        }
        if !volumes.contains(url) { volumes.append(url) }
        await select(.volume(url))
        return true
    }

    func removeVolume(_ url: URL) async {
        volumes.removeAll { $0 == url }
        url.stopAccessingSecurityScopedResource()
        if selectedSource == .volume(url) { await select(.wifi) }
    }
}

enum SettingKey {
    static let autoDisconnect = "autoDisconnectAfterImport"
    static let powerOffWhenDone = "powerOffWhenDone"
    static let thumbnailSize = "thumbnailSize"
}
