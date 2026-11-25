import AppKit
import AVFoundation
import SwiftUI

enum WallpaperSort: String, CaseIterable, Identifiable {
    case featured = "Featured"
    case alphabetical = "Name"
    var id: Self { self }
}

private let accent = Color(nsColor: .systemTeal)
private let softEdge = Color.primary.opacity(0.10)
private let creativeOrder = [
    "record-player.mp4", "crystal-ball.mp4", "lighthouse.mp4",
    "lofi-snowy-evening-walk.mp4", "snow-house.mp4", "vintage-typewriter-lofi-christmas.mp4",
    "waterfall.mp4", "synthwave-outrun-purple-sun.mp4", "workout-greek-god-deadlift.mp4",
    "fireplace-cyberpunk-neon.mp4", "lofi-train-window.mp4", "fireplace-art-deco.mp4",
]

struct WallpaperBrowser: View {
    @ObservedObject var library: WallpaperLibrary
    @FocusState private var searchFocused: Bool

    private var visible: [Wallpaper] {
        let query = library.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = library.items.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
        }
        guard library.sort == .featured else { return matches }
        let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.id, $0) })
        let featured = creativeOrder.compactMap { byID[$0] }
        return featured + matches.filter { !creativeOrder.contains($0.id) }
    }

    private var selected: Wallpaper? {
        visible.first { $0.id == library.selection } ?? visible.first
    }

    var body: some View {
        let results = visible
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                libraryPane(results)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                WallpaperInspector(library: library, wallpaper: selected)
                    .frame(width: 338)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onAppear { if library.selection == nil { library.selection = library.activeID } }
        .onChange(of: library.activeID) { _, current in
            if library.selection == nil { library.selection = current }
        }
        .onChange(of: library.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Wallpaper Library").font(.system(size: 21, weight: .semibold))
                Text("\(library.items.count) wallpapers")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search wallpapers", text: $library.filter)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 270)
                if !library.filter.isEmpty {
                    Button {
                        library.filter = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11).frame(height: 34)
            .background(.quaternary.opacity(0.40), in: .rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(softEdge, lineWidth: 1) }
            Picker("Sort by", selection: $library.sort) {
                ForEach(WallpaperSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Sort wallpapers")
            Menu {
                Button("Choose Wallpaper Folder…") { library.chooseFolder() }
                Button("Show Library in Finder") { library.revealLibrary() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Library options")
            .help("Library options")
        }
        .padding(.horizontal, 23).padding(.vertical, 14)
    }

    private func libraryPane(_ results: [Wallpaper]) -> some View {
        VStack(spacing: 0) {
            if !library.filter.isEmpty && !results.isEmpty {
                Text(results.count == 1 ? "1 result" : "\(results.count) results")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 23)
                    .padding(.top, 16)
                    .padding(.bottom, 7)
            }

            if results.isEmpty {
                Spacer()
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("No wallpaper videos", systemImage: "film.stack")
                    } description: {
                        Text("Choose a folder containing MP4, MOV, or M4V files.")
                    } actions: {
                        Button("Choose Folder…") { library.chooseFolder() }
                    }
                } else {
                    ContentUnavailableView.search(text: library.filter)
                }
                Spacer()
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 179, maximum: 300), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(results) { wallpaper in
                                WallpaperTile(wallpaper: wallpaper,
                                              selected: selected?.id == wallpaper.id,
                                              active: library.activeID == wallpaper.id) {
                                    library.choose(wallpaper)
                                }
                                .id(wallpaper.id)
                            }
                        }
                        .padding(.horizontal, 23).padding(.bottom, 20)
                        .padding(.top, library.filter.isEmpty ? 21 : 7)
                    }
                    .onChange(of: library.currentRevealRequest) { _, _ in
                        if let id = library.activeID { scroll.scrollTo(id, anchor: .center) }
                    }
                }
            }
            if let active = library.currentWallpaper {
                Divider()
                HStack(spacing: 10) {
                    ArtworkImage(url: active.thumbnail, mode: .fill)
                        .frame(width: 47, height: 31)
                        .clipShape(.rect(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(library.paused ? "Desktop paused" : "Playing on desktop")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Library") { library.revealCurrent() }
                        .controlSize(.small)
                        .disabled(!library.items.contains { $0.url == active.url })
                    Button {
                        library.togglePause()
                    } label: {
                        Image(systemName: library.paused ? "play.fill" : "pause.fill")
                            .frame(width: 14)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(library.paused ? "Resume desktop wallpaper" : "Pause desktop wallpaper")
                    .help(library.paused ? "Resume desktop wallpaper" : "Pause desktop wallpaper")
                }
                .padding(.horizontal, 23).padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

private struct WallpaperTile: View {
    let wallpaper: Wallpaper
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { ArtworkImage(url: wallpaper.thumbnail, mode: .fill) }
                    .clipped()
                HStack(spacing: 7) {
                    Text(wallpaper.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
            }
            .background(selected ? accent.opacity(0.10) : Color.primary.opacity(0.035))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? accent : softEdge, lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(wallpaper.title)
        .accessibilityValue(active ? "Current desktop wallpaper" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(wallpaper.title)
    }
}

private struct WallpaperInspector: View {
    @ObservedObject var library: WallpaperLibrary
    let wallpaper: Wallpaper?

    var body: some View {
        ScrollView {
            if let wallpaper {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(wallpaper.title)
                            .font(.system(size: 23, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        HStack {
                            Text(wallpaper.bundled ? "4K video · 3840 × 2160" : wallpaper.url.pathExtension.uppercased() + " video")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if library.activeID == wallpaper.id {
                                Label(library.paused ? "Paused" : "On desktop",
                                      systemImage: library.paused ? "pause.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(accent)
                            }
                        }
                        .font(.caption)
                    }
                    Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            if library.previewID == wallpaper.id {
                                MotionPreview(file: wallpaper.url)
                                    .accessibilityLabel("Animated preview of \(wallpaper.title)")
                            } else {
                                ArtworkImage(url: wallpaper.thumbnail, mode: .fill)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(softEdge) }
                    Button {
                        library.apply(wallpaper)
                    } label: {
                        HStack {
                            if library.loadingID == wallpaper.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "macwindow")
                            }
                            Text("Set as Wallpaper")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ApplyWallpaperStyle())
                    .disabled(library.loadingID == wallpaper.id)
                    Button {
                        library.togglePreview(wallpaper)
                    } label: {
                        Label(library.previewID == wallpaper.id ? "Stop Preview" : "Play Preview",
                              systemImage: library.previewID == wallpaper.id ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)

                    if let icon = NSImage(contentsOf: wallpaper.icon) {
                        Divider().padding(.top, 4)
                        HStack(spacing: 12) {
                            Image(nsImage: icon).resizable().scaledToFill()
                                .frame(width: 52, height: 52).clipShape(Circle())
                                .overlay { Circle().strokeBorder(softEdge) }
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Matching profile icon").font(.subheadline.weight(.semibold))
                                if library.loginIconUpdated && library.activeID == wallpaper.id {
                                    Label("Mac login picture updated", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(accent)
                                } else {
                                    Text("Updates your Mac login picture when applied.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Toggle("Sync Apple Account photo", isOn: Binding(
                                    get: { library.appleAccountPhotoSyncEnabled },
                                    set: { library.setAppleAccountPhotoSyncEnabled($0) }
                                ))
                                .controlSize(.small)
                                if library.appleAccountPhotoSyncEnabled && !library.canSyncAppleAccount {
                                    Button("Open App Control Settings…") { library.openAccessibilitySettings() }
                                        .controlSize(.small)
                                }
                                Button("Open Apple Account Picture…") { library.showAccountPicture(wallpaper) }
                                    .controlSize(.small)
                            }
                        }
                    }

                    if library.activeID == wallpaper.id {
                        accountStatus
                    }

                    if let error = library.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(21)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = library.error {
                ContentUnavailableView("Wallpaper library unavailable", systemImage: "folder",
                                       description: Text(error))
                    .padding(14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    @ViewBuilder private var accountStatus: some View {
        switch library.appleAccountStatus {
        case .idle:
            EmptyView()
        case .permissionRequired:
            Text("Allow Animated Wallpapers to control System Settings to sync your Apple Account picture automatically.")
                .font(.caption).foregroundStyle(.secondary)
        case .dragPermissionUnavailable:
            Text("macOS requires additional mouse-event access for automatic Apple Account changes.")
                .font(.caption).foregroundStyle(.secondary)
        case .updating:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Updating Apple Account picture…").font(.caption)
            }
            .foregroundStyle(.secondary)
        case .saved:
            Label("Apple Account picture saved", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(accent)
        case .submitted:
            Label("Picture sent to Apple Account settings", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(accent)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ApplyWallpaperStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = Color(red: 0.045, green: 0.43, blue: 0.41)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(configuration.isPressed ? fill.opacity(0.73) : fill,
                        in: .rect(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.18)) }
            .opacity(enabled ? 1 : 0.60)
    }
}

private struct ArtworkImage: View {
    let url: URL
    let mode: ContentMode

    var body: some View {
        GeometryReader { geometry in
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: mode)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.primary.opacity(0.06)
                    Image(systemName: "play.rectangle").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MotionPreview: NSViewRepresentable {
    let file: URL

    @MainActor
    final class PlayerView: NSView {
        private let videoLayer = AVPlayerLayer()
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var file: URL?

        override init(frame: NSRect) {
            super.init(frame: frame)
            player.isMuted = true
            videoLayer.player = player
            videoLayer.backgroundColor = NSColor.black.cgColor
            videoLayer.videoGravity = .resizeAspect
            layer = videoLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        func play(_ file: URL) {
            guard self.file != file else { return }
            stop()
            self.file = file
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: file))
            player.play()
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            file = nil
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(frame: .zero)
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.play(file)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }
}
