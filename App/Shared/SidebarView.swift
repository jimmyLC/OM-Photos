import OMKit
import SwiftUI

/// Mac and iPad sidebar: sources, media types, dates.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @State private var selection: SidebarItem?

    var body: some View {
        let library = model.library
        List(selection: $selection) {
            Section("來源") {
                HStack {
                    Label(connection.current?.name ?? connection.cameras.first?.name ?? "相機", systemImage: "wifi")
                    Spacer()
                    Circle()
                        .fill(connection.isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
                .tag(SidebarItem.source(.wifi))

                ForEach(model.volumes, id: \.self) { url in
                    Label(VolumeSource(root: url).displayName, systemImage: "sdcard")
                        .tag(SidebarItem.source(.volume(url)))
                        .contextMenu {
                            #if os(iOS)
                            Button("移除", systemImage: "eject") { Task { await model.removeVolume(url) } }
                            #endif
                        }
                }
                #if os(iOS)
                Button {
                    model.pickingVolume = true
                } label: {
                    Label("連接 USB 記憶卡…", systemImage: "cable.connector")
                }
                #endif
            }

            if library.phase == .loaded, !library.items.isEmpty {
                Section("類型") {
                    ForEach(TypeFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.symbol)
                            .badge(library.count(filter))
                            .tag(SidebarItem.type(filter))
                    }
                }
                Section("日期") {
                    ForEach(library.sections) { section in
                        Text(Days.title(section.day))
                            .badge(section.items.count)
                            .tag(SidebarItem.day(section.day))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OM Transfer")
        .onAppear { selection = .source(model.selectedSource) }
        .onChange(of: model.selectedSource) { _, source in
            if case .source = selection { selection = .source(source) }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            switch item {
            case .source(let source):
                // Ignore echoes of a change that came from the model (e.g. a card plugged in).
                guard source != model.selectedSource || model.library.typeFilter != .all else { return }
                Task { await model.select(source) }
            case .type(let filter):
                library.typeFilter = filter
            case .day(let day):
                model.scrollTarget = day
            }
        }
    }
}

extension TypeFilter {
    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .photos: "photo"
        case .raw: "camera.aperture"
        case .videos: "video"
        }
    }
}

/// iPhone: everything the sidebar offers, in one menu.
struct CompactFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        @Bindable var library = model.library
        Menu {
            Section("來源") {
                Button {
                    Task { await model.select(.wifi) }
                } label: {
                    Label(connection.current?.name ?? "相機（Wi-Fi）", systemImage: model.selectedSource == .wifi ? "checkmark" : "wifi")
                }
                ForEach(model.volumes, id: \.self) { url in
                    Button {
                        Task { await model.select(.volume(url)) }
                    } label: {
                        Label(VolumeSource(root: url).displayName,
                              systemImage: model.selectedSource == .volume(url) ? "checkmark" : "sdcard")
                    }
                }
                Button("連接 USB 記憶卡…", systemImage: "cable.connector") { model.pickingVolume = true }
            }
            if library.phase == .loaded {
                Picker("類型", selection: $library.typeFilter) {
                    ForEach(TypeFilter.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("狀態", selection: $library.statusFilter) {
                    ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                }
                Menu("跳到日期", systemImage: "calendar") {
                    ForEach(library.sections) { section in
                        Button("\(Days.title(section.day))（\(section.items.count)）") { model.scrollTarget = section.day }
                    }
                }
            }
        } label: {
            Label("篩選", systemImage: library.typeFilter == .all && library.statusFilter == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }
}
