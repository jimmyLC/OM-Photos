import OMKit
import SwiftUI

/// Right-hand side: the connection screen or the photo grid of the selected source.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        Group {
            if model.selectedSource == .wifi && !connection.isConnected {
                ConnectionPanel()
            } else {
                LibraryContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        switch library.phase {
        case .noSource:
            ConnectionPanel()
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text(model.selectedSource == .wifi ? "正在讀取相機裡的檔案…" : "正在讀取記憶卡…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("讀不到檔案", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("再試一次") { Task { await library.reload() } }
                    .buttonStyle(.glassProminent)
            }
        case .loaded:
            if library.items.isEmpty {
                ContentUnavailableView("記憶卡裡沒有照片或影片", systemImage: "photo.on.rectangle.angled")
            } else if library.filtered.isEmpty {
                ContentUnavailableView("沒有符合篩選的項目", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("試試看「全部」。"))
            } else {
                PhotoGrid()
            }
        }
    }
}

// MARK: - Grid

struct PhotoGrid: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.thumbnailSize) private var cellSize: Double = PhotoGrid.defaultSize
    @State private var pinchBase: Double?
    @FocusState private var focused: Bool

    #if os(macOS)
    static let defaultSize = 150.0
    #else
    static let defaultSize = 110.0
    #endif
    static let sizeRange = 70.0...320.0

    var body: some View {
        let library = model.library
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.6), spacing: 2)],
                          spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(library.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                PhotoCell(item: item, selected: library.selection.contains(item.id))
                                    .id(item.id)
                            }
                        } header: {
                            DayHeader(section: section).id(section.day)
                        }
                    }
                }
                .padding(.bottom, 60)
            }
            .onChange(of: model.scrollTarget) { _, day in
                guard let day else { return }
                withAnimation(.smooth) { proxy.scrollTo(day, anchor: .top) }
                model.scrollTarget = nil
            }
        }
        .safeAreaInset(edge: .bottom) { SummaryBar() }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? cellSize
                    pinchBase = base
                    cellSize = min(max(base * value.magnification, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.space) {
            guard let id = library.selection.first else { return .ignored }
            model.viewing = id
            return .handled
        }
        .onKeyPress(.escape) {
            library.clearSelection()
            return .handled
        }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            library.selectAll()
            return .handled
        }
    }
}

struct DayHeader: View {
    let section: DaySection

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Days.title(section.day)).font(.headline)
            Text("\(section.items.count) 項").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct PhotoCell: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    let selected: Bool

    var body: some View {
        Thumbnail(item: item)
            .overlay(alignment: .bottomLeading) { badges }
            .overlay(alignment: .topTrailing) { marks }
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    Color.accentColor.opacity(0.12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            .accessibilityLabel("\(item.badge)，\(item.date.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task(id: item.id) { await model.library.loadMovieInfo(for: item) }
    }

    private var badges: some View {
        HStack(spacing: 4) {
            Text(item.badge)
            if item.isVideo, let duration = model.library.movieInfo[item.id]?.durationText {
                Image(systemName: "play.fill").imageScale(.small)
                Text(duration).monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(5)
    }

    private var marks: some View {
        HStack(spacing: 4) {
            if item.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: Circle())
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
            }
        }
        .padding(5)
    }

    private func tap() {
        let library = model.library
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if NSApp.currentEvent?.clickCount == 2 {
            model.viewing = item.id
            return
        }
        library.select(item, extend: flags.contains(.shift), toggle: flags.contains(.command))
        #else
        if model.selecting {
            library.select(item, extend: false, toggle: true)
        } else {
            model.viewing = item.id
        }
        #endif
    }
}

struct Thumbnail: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if failed {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: item.id) {
                if let img = await model.library.thumbnail(for: item) {
                    withAnimation(.easeOut(duration: 0.15)) { image = img }
                } else if !Task.isCancelled {
                    failed = true
                }
            }
    }
}

/// Bottom bar: item count, or the selection and its size.
struct SummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        HStack(spacing: 10) {
            if library.selection.isEmpty {
                Text("\(library.filtered.count) 個項目")
            } else {
                Text("已選 \(library.selectedItems.count) 項 · \(library.selectedSize.formatted(.byteCount(style: .file)))")
                Button("取消選取") { library.clearSelection() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(in: Capsule())
        .padding(.bottom, 10)
        .animation(.smooth, value: library.selection.count)
    }
}
