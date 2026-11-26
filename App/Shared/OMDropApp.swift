import OMKit
import SwiftUI

@main
struct OMDropApp: App {
    @State private var model: AppModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: MacAppDelegate
    #endif

    init() {
        #if os(macOS)
        let joiner: WiFiJoining = CoreWLANJoiner()
        #else
        let joiner: WiFiJoining = PlatformJoiner.make()
        #endif
        let model = AppModel(connection: ConnectionManager(store: KeychainCameraStore(), joiner: joiner))
        _model = State(initialValue: model)
        #if os(macOS)
        model.startWithCards(VolumeWatcher.currentCards())
        MacAppDelegate.model = model
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.connection)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.connection)
                .frame(width: 520, height: 640)
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.connection)
        }
        #endif
    }
}

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    @MainActor private var watcher: VolumeWatcher?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.model else { return }
        watcher = VolumeWatcher { urls in
            Task { await model.setVolumes(urls) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Switch the Wi-Fi back before the app quits.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let connection = Self.model?.connection, connection.joinedByApp else { return .terminateNow }
        Task { @MainActor in
            await connection.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
