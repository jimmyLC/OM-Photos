import OMKit
import SwiftUI

enum SettingKey {
    static let autoDisconnect = "autoDisconnectAfterImport"
}

struct SettingsView: View {
    @Environment(ConnectionManager.self) private var connection
    @AppStorage(SettingKey.autoDisconnect) private var autoDisconnect = true
    @State private var confirmForget: PairedCamera?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if connection.cameras.isEmpty {
                    Text("還沒有配對的相機").foregroundStyle(.secondary)
                }
                ForEach(connection.cameras) { camera in
                    CameraRow(camera: camera) { name in
                        do { try connection.rename(camera, to: name) } catch { self.error = error.localizedDescription }
                    } forget: {
                        confirmForget = camera
                    }
                }
            } header: {
                Text("已配對的相機")
            } footer: {
                Text("相機的 Wi-Fi 密碼存在鑰匙圈，並透過 iCloud 鑰匙圈同步到你的其他裝置。")
            }

            Section("連線") {
                Toggle("匯入完成後自動中斷並切回原本的 Wi-Fi", isOn: $autoDisconnect)
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
        .confirmationDialog("移除「\(confirmForget?.name ?? "")」？", isPresented: .init(
            get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }
        ), titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                guard let camera = confirmForget else { return }
                Task {
                    do { try await connection.forget(camera) } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("所有裝置上都會移除這台相機的配對資料，之後要重新掃描 QR code。相機裡的照片不受影響。")
        }
    }
}

private struct CameraRow: View {
    let camera: PairedCamera
    let rename: (String) -> Void
    let forget: () -> Void
    @State private var name = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("名稱", text: $name)
                    .onSubmit { rename(name) }
                    .font(.body.weight(.medium))
                Text(camera.credentials.ssid)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("移除", role: .destructive, action: forget)
                .buttonStyle(.borderless)
        }
        .onAppear { name = camera.name }
        .onChange(of: camera.name) { _, new in name = new }
    }
}
