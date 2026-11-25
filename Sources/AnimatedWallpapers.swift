import AppKit
import AVFoundation
import CoreServices
import OSLog
import ServiceManagement
import SwiftUI

struct Wallpaper: Identifiable {
    let url: URL
    let title: String
    let thumbnail: URL
    let bundled: Bool
    let icon: URL
    var id: String { url.lastPathComponent }
}

@MainActor
final class WallpaperLibrary: NSObject, ObservableObject, NSWindowDelegate {
    @Published var filter = "" {
        didSet { if filter != oldValue { previewID = nil } }
    }
    @Published var selection: String?
    @Published var sort: WallpaperSort = .featured
    @Published private(set) var currentWallpaper: Wallpaper?
    @Published private(set) var previewID: String?
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var currentRevealRequest = 0
    private var libraryFolder: URL?
    private let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Gifpapers/4K Wallpapers", isDirectory: true)
    private let installedFolder = URL(fileURLWithPath: "/Library/Application Support/Animated Wallpapers/Library/4K Wallpapers", isDirectory: true)
    @Published private(set) var items: [Wallpaper] = []
    @Published private(set) var activeID: String?
    @Published private(set) var readyID: String?
    @Published private(set) var setupCompleted = UserDefaults.standard.bool(forKey: "InitialSetupCompleted")
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var appleAccountPhotoSyncEnabled = UserDefaults.standard.bool(forKey: "AppleAccountPhotoSyncEnabled")
    @Published private(set) var paused = false
    @Published private(set) var loadingID: String?
    @Published private(set) var error: String?
    @Published private(set) var loginIconUpdated = false
    @Published private(set) var canSyncAppleAccount = false
    @Published private(set) var appleAccountStatus: AppleAccountSyncState = .idle
    private let appleAccountSync = AppleAccountSync()
    private let profilePictureUpdater = ProfilePictureUpdater()
    private let profileLog = Logger(subsystem: "local.gifpapers.animated-wallpapers", category: "profile")
    private var selectionNumber = 0
    private var pendingLoginIcon: (url: URL, selection: Int)?
    private let defaults = UserDefaults.standard
    private let titles: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Titles", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let titles = try? PropertyListDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return titles
    }()
    private var surfaces: [NSNumber: DesktopSurface] = [:]
    private var activeAsset: AVURLAsset?
    private var loadTask: Task<Void, Never>?
    private var displayAsleep = false
    private var inactiveSession = false
    private var window: NSWindow?
    private var browserPresentation = 0
    private var pendingBrowserClose: (selection: Int, presentation: Int)?
    private var accountPicturePanel: NSPanel?
    private var pauseItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    func attachMenu(_ menu: NSMenu) {
        pauseItem = menu.items.first { $0.action == #selector(AppDelegate.togglePause) }
        loginItem = menu.items.first { $0.action == #selector(AppDelegate.toggleLogin) }
        updateMenu()
    }

    func start() {
        refreshAccountPermission()
        paused = defaults.bool(forKey: "Paused")
        let manager = FileManager.default
        let oldFolder = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Gifpapers/4K Wallpapers", isDirectory: true)
        let savedFolder = defaults.string(forKey: "WallpaperFolder").map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let preferred = savedFolder.flatMap { $0 == oldFolder ? nil : $0 } ?? defaultFolder
        for folder in [preferred, defaultFolder, installedFolder] where items.isEmpty {
            try? loadFolder(folder)
        }
        if items.isEmpty {
            error = "Choose a folder containing MP4 or MOV wallpapers."
        }
        let initial = items.first { $0.id == defaults.string(forKey: "Wallpaper") }
            ?? items.first { $0.id == "record-player.mp4" }
            ?? items.first
        if let initial {
            if setupCompleted || defaults.string(forKey: "Wallpaper") != nil {
                apply(initial, resume: false)
            } else {
                choose(initial)
            }
        }
    }

    private func loadFolder(_ folder: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                                 options: .skipsHiddenFiles)
        let library = folder.deletingLastPathComponent()
        let posters = library.appendingPathComponent("Desktop Stills", isDirectory: true)
        let icons = library.appendingPathComponent("User Icons", isDirectory: true)
        let usesCatalog = [defaultFolder, installedFolder].contains(folder.standardizedFileURL)
        libraryFolder = library
        items = entries.filter {
            ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let title = titles[name] ?? name.replacingOccurrences(of: "-", with: " ").capitalized
            let thumbnail = usesCatalog
                ? Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Thumbnails")
                : nil
            return Wallpaper(url: url, title: title,
                             thumbnail: thumbnail ?? posters.appendingPathComponent(name + ".jpg"),
                             bundled: usesCatalog && titles[name] != nil,
                             icon: icons.appendingPathComponent(name + ".png"))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select a folder containing your wallpaper videos."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try loadFolder(folder)
            if items.isEmpty {
                error = "This folder contains no MP4, MOV, or M4V wallpapers."
            } else {
                previewID = nil
                filter = ""
                selection = items.first { $0.url == currentWallpaper?.url }?.id
                defaults.set(folder.path, forKey: "WallpaperFolder")
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func choose(_ wallpaper: Wallpaper) {
        if selection != wallpaper.id { previewID = nil }
        selection = wallpaper.id
    }

    func togglePreview(_ wallpaper: Wallpaper) {
        choose(wallpaper)
        previewID = previewID == wallpaper.id ? nil : wallpaper.id
    }

    func focusSearch() {
        showBrowser()
        searchFocusRequest += 1
    }

    func revealLibrary() {
        if let libraryFolder {
            NSWorkspace.shared.activateFileViewerSelecting([libraryFolder])
        }
    }

    func revealCurrent() {
        guard let currentWallpaper else { return }
        filter = ""
        choose(currentWallpaper)
        currentRevealRequest += 1
    }

    func apply(_ wallpaper: Wallpaper, resume: Bool = true) {
        if resume {
            choose(wallpaper)
            previewID = nil
        }
        loadTask?.cancel()
        selectionNumber += 1
        let request = selectionNumber
        pendingBrowserClose = resume && setupCompleted && window?.isVisible == true ? (request, browserPresentation) : nil
        readyID = nil
        pendingLoginIcon = nil
        loginIconUpdated = false
        appleAccountStatus = .idle
        loadingID = wallpaper.id
        error = nil
        loadTask = Task {
            do {
                let asset = AVURLAsset(url: wallpaper.url)
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard !Task.isCancelled else { return }
                guard playable, !tracks.isEmpty else {
                    error = "macOS could not play this wallpaper."
                    loadingID = nil
                    return
                }
                if resume {
                    paused = false
                    defaults.set(false, forKey: "Paused")
                    if FileManager.default.fileExists(atPath: wallpaper.icon.path) {
                        pendingLoginIcon = (wallpaper.icon, request)
                    }
                }
                activeAsset = asset
                activeID = wallpaper.id
                currentWallpaper = wallpaper
                if resume, let panel = accountPicturePanel, panel.isVisible,
                   FileManager.default.fileExists(atPath: wallpaper.icon.path) {
                    panel.contentView = NSHostingView(rootView: AccountPicturePanel(wallpaper: wallpaper))
                }
                defaults.set(wallpaper.id, forKey: "Wallpaper")
                rebuildSurfaces(replaceVideo: true)
                loadingID = nil
                updateMenu()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loadingID = nil
            }
        }
    }

    func screensChanged() {
        rebuildSurfaces(replaceVideo: false)
    }

    private func rebuildSurfaces(replaceVideo: Bool) {
        guard let asset = activeAsset else { return }
        var screenIDs = Set<NSNumber>()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            screenIDs.insert(number)
            let existing = surfaces[number]
            let surface = existing ?? DesktopSurface(screen: screen)
            surfaces[number] = surface
            surface.resize(to: screen)
            surface.setPaused(paused, sessionInactive: displayAsleep || inactiveSession)
            if replaceVideo || existing == nil {
                let selection = selectionNumber
                surface.present(asset) { [weak self] in
                    guard let self, self.activeAsset === asset, self.selectionNumber == selection else { return }
                    self.desktopDidPresent(selection: selection)
                } onError: { [weak self] message in
                    if self?.activeAsset === asset { self?.error = message }
                }
            }
        }
        for number in Set(surfaces.keys).subtracting(screenIDs) {
            surfaces.removeValue(forKey: number)?.close()
        }
    }

    func setAppleAccountPhotoSyncEnabled(_ enabled: Bool) {
        appleAccountPhotoSyncEnabled = enabled
        defaults.set(enabled, forKey: "AppleAccountPhotoSyncEnabled")
    }

    func completeSetup() {
        defaults.set(true, forKey: "InitialSetupCompleted")
        window?.close()
        setupCompleted = true
        for key in ["FirstLaunchWizardStep", "FirstLaunchWizardWallpaper", "FirstLaunchWizardSyncAccount"] {
            defaults.removeObject(forKey: key)
        }
    }

    func refreshSystemSettings() {
        refreshAccountPermission()
        updateMenu()
    }

    func refreshAccountPermission() {
        canSyncAppleAccount = AppleAccountSync.isTrusted
        if canSyncAppleAccount { defaults.set(true, forKey: "AppleAccountSyncPreviouslyAuthorized") }
    }

    func openAccessibilitySettings() {
        AppleAccountSync.openAccessibilitySettings()
    }

    private func desktopDidPresent(selection: Int) {
        readyID = activeID
        let presentation = pendingBrowserClose?.selection == selection ? pendingBrowserClose?.presentation : nil
        pendingBrowserClose = nil
        if pendingLoginIcon?.selection == selection {
            syncLoginIcon(selection: selection, closingPresentation: presentation)
        } else {
            closeBrowser(presentation: presentation)
        }
    }

    private func closeBrowser(presentation: Int?) {
        guard let presentation, presentation == browserPresentation else { return }
        window?.close()
        let log = Logger(subsystem: "local.gifpapers.animated-wallpapers", category: "library")
        log.notice("Wallpaper applied. Chooser closed and Dock icon hidden.")
    }

    private func syncLoginIcon(selection: Int, closingPresentation: Int?) {
        guard let pending = pendingLoginIcon, pending.selection == selection else { return }
        pendingLoginIcon = nil
        Task { [self] in
            do {
                if try await profilePictureUpdater.apply(pending.url, selection: selection) {
                    let name = pending.url.lastPathComponent
                    profileLog.notice("Updated local Mac login picture from \(name, privacy: .public)")
                    if selection == selectionNumber { loginIconUpdated = true }
                }
            } catch {
                profileLog.error("Mac login picture update failed: \(error.localizedDescription, privacy: .public)")
                if selection == selectionNumber {
                    self.error = "Wallpaper applied. Mac login picture: \(error.localizedDescription)"
                }
            }
            guard selection == selectionNumber else { return }
            guard appleAccountPhotoSyncEnabled, !inactiveSession, !displayAsleep else {
                closeBrowser(presentation: closingPresentation)
                return
            }
            refreshAccountPermission()
            if canSyncAppleAccount { accountPicturePanel?.orderOut(nil) }
            appleAccountSync.submit(pending.url,
                                    reopenSettings: defaults.bool(forKey: "AppleAccountSyncPreviouslyAuthorized")) { [weak self] state in
                guard let self, selection == self.selectionNumber else { return }
                if state == .permissionRequired {
                    self.defaults.removeObject(forKey: "AppleAccountSyncPreviouslyAuthorized")
                    self.canSyncAppleAccount = false
                }
                self.appleAccountStatus = state
                if state != .updating {
                    self.closeBrowser(presentation: closingPresentation)
                }
            }
        }
    }

    func setSessionInactive(_ inactive: Bool) {
        inactiveSession = inactive
        updatePlaybackState()
    }

    func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        updatePlaybackState()
    }

    func togglePause() {
        paused.toggle()
        defaults.set(paused, forKey: "Paused")
        updatePlaybackState()
        updateMenu()
    }

    private func updatePlaybackState() {
        for surface in surfaces.values {
            surface.setPaused(paused, sessionInactive: displayAsleep || inactiveSession)
        }
    }

    private func updateMenu() {
        pauseItem?.title = paused ? "Resume Wallpaper" : "Pause Wallpaper"
        pauseItem?.isEnabled = activeID != nil
        loginStatus = SMAppService.mainApp.status
        loginItem?.state = loginStatus == .enabled ? .on : .off
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateMenu()
        } catch {
            self.error = error.localizedDescription
            showBrowser()
        }
    }

    func showAccountPicture(_ wallpaper: Wallpaper) {
        guard FileManager.default.fileExists(atPath: wallpaper.icon.path) else { return }
        let settings = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!
        if !NSWorkspace.shared.open(settings) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                NSWorkspace.shared.open(url)
            }
        }

        let panel: NSPanel
        if let existing = accountPicturePanel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 219),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.title = "Apple Account Picture"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let screen {
                panel.setFrameOrigin(NSPoint(x: screen.minX + 28, y: screen.minY + 48))
            }
            accountPicturePanel = panel
        }
        panel.contentView = NSHostingView(rootView: AccountPicturePanel(wallpaper: wallpaper))
        panel.orderFrontRegardless()
    }

    func showBrowser() {
        browserPresentation += 1
        let browser: NSWindow
        if let window {
            browser = window
        } else {
            browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1130, height: 745),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            browser.title = "Animated Wallpapers"
            browser.isReleasedWhenClosed = false
            browser.minSize = NSSize(width: 895, height: 535)
            browser.delegate = self
            browser.contentView = NSHostingView(rootView: WallpaperLibraryContent(library: self))
            browser.center()
            browser.setFrameAutosaveName("WallpaperLibrary")
            window = browser
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        browser.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        browserPresentation += 1
        previewID = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = WallpaperLibrary()
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = launchEvent?.eventID == kAEOpenApplication
            && launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        installMainMenu()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.fill",
                                          accessibilityDescription: "Animated Wallpapers")
        statusItem.button?.toolTip = "Animated Wallpapers"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [
            ("Choose Wallpaper…", #selector(showBrowser)),
            ("Pause Wallpaper", #selector(togglePause)),
            ("Open at Login", #selector(toggleLogin)),
        ] {
            let actionItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            actionItem.target = self
            menu.addItem(actionItem)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Animated Wallpapers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        item = statusItem
        library.attachMenu(menu)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(wentToSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        library.start()
        if !CommandLine.arguments.contains("--background"), !launchedAtLogin {
            library.showBrowser()
        }
    }

    private func installMainMenu() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let contents = NSMenu(title: title)
            header.submenu = contents
            bar.addItem(header)
            return contents
        }
        func command(_ title: String, _ action: Selector, _ shortcut: String = "",
                     target: AnyObject? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
            entry.target = target
            return entry
        }
        let app = menu("Animated Wallpapers")
        app.addItem(command("About Animated Wallpapers", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(command("Hide Animated Wallpapers", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        let hideOthers = command("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(command("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        app.addItem(.separator())
        app.addItem(command("Quit Animated Wallpapers", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        let file = menu("File")
        file.addItem(command("Choose Wallpaper Folder…", #selector(chooseFolder), "o", target: self))
        file.addItem(command("Show Library in Finder", #selector(revealLibrary), target: self))
        file.addItem(.separator())
        file.addItem(command("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        let edit = menu("Edit")
        edit.addItem(command("Undo", Selector(("undo:")), "z"))
        let redo = command("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(command("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(command("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(command("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(command("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(command("Find Wallpaper", #selector(focusSearch), "f", target: self))
        let windows = menu("Window")
        windows.addItem(command("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windows.addItem(command("Zoom", #selector(NSWindow.performZoom(_:))))
        windows.addItem(.separator())
        windows.addItem(command("Show Wallpaper Library", #selector(showBrowser), "1", target: self))
        NSApp.windowsMenu = windows
        NSApp.mainMenu = bar
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        library.refreshSystemSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        library.showBrowser()
        return false
    }

    @objc func showBrowser() { library.showBrowser() }
    @objc func focusSearch() { library.focusSearch() }
    @objc func chooseFolder() { library.showBrowser(); library.chooseFolder() }
    @objc func revealLibrary() { library.revealLibrary() }
    @objc func togglePause() { library.togglePause() }
    @objc func toggleLogin() { library.toggleLogin() }
    @objc func screensChanged() { library.screensChanged() }
    @objc func wentToSleep() { library.setDisplayAsleep(true) }
    @objc func wokeUp() { library.setDisplayAsleep(false) }
    @objc func sessionResigned() { library.setSessionInactive(true) }
    @objc func sessionActivated() { library.setSessionInactive(false) }
}

@main
struct AnimatedWallpapers {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
