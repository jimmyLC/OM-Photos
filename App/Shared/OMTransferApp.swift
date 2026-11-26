import OMKit
import SwiftUI

@main
struct OMTransferApp: App {
    @State private var connection: ConnectionManager
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: MacAppDelegate
    #endif

    init() {
        #if os(macOS)
        let joiner: WiFiJoining = CoreWLANJoiner()
        #else
        let joiner: WiFiJoining = PlatformJoiner.make()
        #endif
        let manager = ConnectionManager(store: KeychainCameraStore(), joiner: joiner)
        _connection = State(initialValue: manager)
        #if os(macOS)
        MacAppDelegate.connection = manager
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView().environment(connection)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(connection)
                .frame(width: 520, height: 420)
        }
        #else
        WindowGroup {
            RootView().environment(connection)
        }
        #endif
    }
}

#if os(macOS)
/// Switch the Wi-Fi back before the app quits.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var connection: ConnectionManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let connection = Self.connection, connection.joinedByApp else { return .terminateNow }
        Task { @MainActor in
            await connection.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
