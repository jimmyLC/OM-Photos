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
                    Label(connection.displayName, systemImage: "wifi")
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
        .navigationTitle("OM Drop")
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

/// iPhone/iPad filter button (as in Photos): type, status, date, and on iPhone the source.
struct FilterMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    var includesSources = true

    var body: some View {
        @Bindable var library = model.library
        let filtering = library.typeFilter != .all || library.statusFilter != .all
        Menu {
            if library.phase == .loaded {
                Picker("類型", selection: $library.typeFilter) {
                    ForEach(TypeFilter.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("狀態", selection: $library.statusFilter) {
                    ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Menu("跳到日期", systemImage: "calendar") {
                    ForEach(library.sections) { section in
                        Button("\(Days.title(section.day))（\(section.items.count)）") { model.scrollTarget = section.day }
                    }
                }
                if filtering {
                    Button("清除篩選", systemImage: "xmark.circle") {
                        library.typeFilter = .all
                        library.statusFilter = .all
                    }
                }
            }
            if includesSources {
                Section("來源") {
                    Button {
                        Task { await model.select(.wifi) }
                    } label: {
                        Label(connection.displayName, systemImage: model.selectedSource == .wifi ? "checkmark" : "wifi")
                    }
                    ForEach(model.volumes, id: \.self) { url in
                        Button {
                            Task { await model.select(.volume(url)) }
                        } label: {
                            Label(VolumeSource(root: url).displayName,
                                  systemImage: model.selectedSource == .volume(url) ? "checkmark" : "sdcard")
                        }
                    }
                    #if os(iOS)
                    Button("連接 USB 記憶卡…", systemImage: "cable.connector") { model.pickingVolume = true }
                    #endif
                }
            }
        } label: {
            Label("篩選", systemImage: "line.3.horizontal.decrease")
        }
        .tint(filtering ? .blue : nil)
    }
}
