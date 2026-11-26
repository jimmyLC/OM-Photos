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

    let importer: Importer
    /// Import waiting for the user's OK (shows count, size and time first).
    var pendingImport: PendingImport?
    /// Source cache key that was auto-imported already (once per load).
    private var autoImportedSource: String?

    struct PendingImport: Identifiable {
        let id = UUID()
        let items: [MediaItem]
        let title: String
        let bytes: Int64
        let seconds: TimeInterval
        let destination: String
    }

    init(connection: ConnectionManager) {
        self.connection = connection
        connection.powerOffWhenDone = UserDefaults.standard.object(forKey: SettingKey.powerOffWhenDone) as? Bool ?? true
        let ledger = ImportLedger()
        importer = Importer(ledger: ledger)
        library.ledger = ledger
        importer.onItemImported = { [weak self] item in self?.library.importedIDs.insert(item.id) }
        importer.onRunningChange = { running in KeepAwake.set(running) }
    }

    // MARK: Import

    var newItemCount: Int { library.items.count - library.importedIDs.count }

    func askImportNew() {
        prepare(importer.newItems(library.items), title: "匯入所有新項目")
    }

    func askImportSelected() {
        prepare(library.selectedItems, title: "匯入選取的項目")
    }

    func retryFailed() {
        let items = importer.failedItems
        importer.dismissSummary()
        prepare(items, title: "重試失敗的項目")
    }

    private func prepare(_ items: [MediaItem], title: String) {
        guard let source = library.source, !items.isEmpty, !importer.isRunning else { return }
        let estimate = Importer.estimate(items, source: source)
        pendingImport = PendingImport(items: items, title: title, bytes: estimate.bytes,
                                      seconds: estimate.seconds, destination: ImportSettings.destinationTitle)
    }

    func confirmImport(_ pending: PendingImport) {
        pendingImport = nil
        guard let source = library.source else { return }
        do {
            importer.start(pending.items, from: source, to: try ImportSettings.destination())
        } catch {
            importError = error.localizedDescription
        }
    }

    var importError: String?

    /// After the list loads: import new items automatically if the user turned that on.
    func autoImportIfWanted() {
        guard UserDefaults.standard.bool(forKey: SettingKey.autoImport), library.phase == .loaded,
              let source = library.source, autoImportedSource != source.cacheKey, !importer.isRunning else { return }
        autoImportedSource = source.cacheKey
        let items = importer.newItems(library.items)
        guard !items.isEmpty else { return }
        do {
            importer.start(items, from: source, to: try ImportSettings.destination())
        } catch {
            importError = error.localizedDescription
        }
    }

    /// After an import over Wi-Fi: switch back to the normal network if the user wants that.
    func afterImport(_ summary: ImportSummary) async {
        let wanted = UserDefaults.standard.object(forKey: SettingKey.autoDisconnect) as? Bool ?? true
        guard wanted, selectedSource == .wifi, connection.isConnected, summary.imported > 0,
              summary.failed.isEmpty, !summary.cancelled, summary.error == nil else { return }
        await connection.disconnect()
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
    static let autoImport = "autoImportOnConnect"
    static let destinationKind = "destinationKind"
    static let destinationFolderPath = "destinationFolderPath"
    static let destinationFolderBookmark = "destinationFolderBookmark"
}
