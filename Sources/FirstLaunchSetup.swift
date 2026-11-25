import AppKit
import ServiceManagement
import SwiftUI

struct WallpaperLibraryContent: View {
    @ObservedObject var library: WallpaperLibrary

    var body: some View {
        if library.setupCompleted {
            WallpaperBrowser(library: library)
        } else {
            FirstLaunchSetup(library: library)
        }
    }
}

@MainActor
private struct FirstLaunchSetup: View {
    @ObservedObject var library: WallpaperLibrary
    @AppStorage("FirstLaunchWizardStep") private var step = 0
    @AppStorage("FirstLaunchWizardWallpaper") private var wallpaperID = ""
    @AppStorage("FirstLaunchWizardSyncAccount") private var syncAccountPhoto = false
    @State private var checkRequest = 0
    @State private var appliedID: String?
    @State private var lockScreen: LockScreenStatus = .idle

    private enum LockScreenStatus {
        case idle, checking, selected, pending
    }

    private var wallpaper: Wallpaper? {
        library.items.first { $0.id == wallpaperID }
    }

    private var hasMatchingIcon: Bool {
        wallpaper.map { FileManager.default.isReadableFile(atPath: $0.icon.path) } ?? false
    }

    private var desktopReady: Bool {
        appliedID != nil && library.readyID == appliedID
    }

    private var canFinish: Bool {
        guard desktopReady, lockScreen != .checking else { return false }
        guard hasMatchingIcon else { return true }
        guard library.loginIconUpdated || library.error != nil else { return false }
        if !syncAccountPhoto { return true }
        return library.appleAccountStatus != .idle && library.appleAccountStatus != .updating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Set up Animated Wallpapers")
                        .font(.title2.weight(.semibold))
                    ProgressView(value: Double(step + 1), total: 3)
                        .accessibilityLabel("Setup progress")
                        .accessibilityValue("Step \(step + 1) of 3")
                }
            }
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case 0: wallpaperStep
                    case 1: accountStep
                    default: applyStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") {
                        step -= 1
                        appliedID = nil
                        lockScreen = .idle
                        checkRequest += 1
                    }
                    .disabled(library.appleAccountStatus == .updating)
                }
                Spacer()
                if step < 2 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(wallpaper == nil)
                } else if appliedID == nil {
                    Button("Apply Wallpaper", action: applyWallpaper)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(wallpaper == nil)
                } else {
                    if library.loadingID == nil && library.appleAccountStatus != .updating {
                        Button("Apply Again", action: applyWallpaper)
                    }
                    Button("Finish Setup") { library.completeSetup() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canFinish)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 660, maxHeight: 610, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if wallpaper == nil { chooseInitialWallpaper() }
            library.refreshSystemSettings()
        }
        .task(id: checkRequest) { await checkLockScreen() }
    }

    private var wallpaperStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your first wallpaper").font(.headline)
            if library.items.isEmpty {
                Text("The wallpaper library could not be opened.")
                Button("Choose Wallpaper Folder…") {
                    library.chooseFolder()
                    chooseInitialWallpaper()
                }
            } else {
                Picker("Wallpaper", selection: $wallpaperID) {
                    ForEach(library.items) { wallpaper in
                        Text(wallpaper.title).tag(wallpaper.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("First wallpaper")
                if let wallpaper, let thumbnail = NSImage(contentsOf: wallpaper.thumbnail) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 136)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(.rect(cornerRadius: 10))
                        .accessibilityHidden(true)
                }
            }

            Divider().padding(.vertical, 2)
            if library.loginStatus == .requiresApproval {
                Label("Open at Login is waiting for approval.", systemImage: "exclamationmark.circle")
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } else {
                Toggle("Open at Login", isOn: Binding(
                    get: { library.loginStatus == .enabled },
                    set: { enabled in
                        if enabled != (library.loginStatus == .enabled) { library.toggleLogin() }
                    }
                ))
                Text("Resume your wallpaper automatically after signing in.")
                    .foregroundStyle(.secondary)
            }
            if let error = library.error, !library.items.isEmpty {
                Text(error).foregroundStyle(.secondary)
            }
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profile pictures").font(.headline)
            Text("Applying a wallpaper also sets its matching Mac login picture.")
                .foregroundStyle(.secondary)
            Toggle("Also sync my Apple Account photo", isOn: $syncAccountPhoto)
            if syncAccountPhoto {
                if AppleAccountSync.usesAppProtectionOverride {
                    Text("In Privacy & Security, open System & App Protection Override and add Animated Wallpapers from Applications.")
                    Text("Choose Bypass System Protections to allow the automatic photo save. This gives the app full control of your Mac and apps.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("In Privacy & Security, open Accessibility and allow Animated Wallpapers from Applications.")
                }
                Button("Open Privacy & Security…") { library.openAccessibilitySettings() }
                Text("Continue after granting access. If macOS asks you to quit and reopen, setup will resume here when you return.")
                    .foregroundStyle(.secondary)
            } else {
                Text("You can turn on Apple Account photo sync later from the wallpaper library.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var applyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apply and check your wallpaper").font(.headline)
            if let wallpaper {
                Text(wallpaper.title).font(.title3.weight(.semibold))
            }
            if appliedID == nil {
                Text("Apply this wallpaper to check playback and your selected settings.")
                    .foregroundStyle(.secondary)
            } else {
                status(desktopReady ? "Animated desktop is playing" : "Starting desktop playback",
                       complete: desktopReady)
                switch lockScreen {
                case .idle, .checking:
                    status("Preparing the Lock Screen video", complete: false)
                case .selected:
                    status("Matching Lock Screen video selected", complete: true)
                case .pending:
                    Label("Lock Screen video is still pending", systemImage: "clock")
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    Text("Check that the Animated Wallpapers background item is allowed.")
                        .foregroundStyle(.secondary)
                }

                if hasMatchingIcon {
                    status(library.loginIconUpdated ? "Mac login picture updated" : "Updating Mac login picture",
                           complete: library.loginIconUpdated)
                }
                if syncAccountPhoto && hasMatchingIcon {
                    appleAccountResult
                }
                if let error = library.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                if lockScreen == .selected {
                    Text("Press Control–Command–Q to see the animation on your Lock Screen.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var appleAccountResult: some View {
        switch library.appleAccountStatus {
        case .idle, .updating:
            status("Updating Apple Account photo", complete: false)
        case .saved:
            status("Apple Account photo saved", complete: true)
        case .submitted:
            Label("Apple Account photo sent to System Settings", systemImage: "arrow.up.circle")
        case .permissionRequired, .dragPermissionUnavailable:
            Label("Apple Account photo sync needs permission", systemImage: "exclamationmark.circle")
            Button("Open Privacy & Security…") { library.openAccessibilitySettings() }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
        }
    }

    private func status(_ text: String, complete: Bool) -> some View {
        Label(text, systemImage: complete ? "checkmark.circle.fill" : "clock")
            .foregroundStyle(complete ? Color.accentColor : Color.secondary)
    }

    private func chooseInitialWallpaper() {
        wallpaperID = library.currentWallpaper?.id
            ?? library.items.first { $0.id == "lighthouse.mp4" }?.id
            ?? library.items.first?.id
            ?? ""
    }

    private func applyWallpaper() {
        guard let wallpaper else { return }
        library.setAppleAccountPhotoSyncEnabled(syncAccountPhoto)
        lockScreen = .checking
        appliedID = wallpaper.id
        checkRequest += 1
        library.apply(wallpaper)
    }

    private func checkLockScreen() async {
        guard let appliedID, let wallpaper, wallpaper.id == appliedID else { return }
        let deadline = ContinuousClock.now + .seconds(24)
        repeat {
            if Self.selectedLockScreenTitle() == wallpaper.title {
                lockScreen = .selected
                return
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        } while ContinuousClock.now < deadline
        lockScreen = .pending
    }

    private static func selectedLockScreenTitle() -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.wallpaper")
        guard let storeData = try? Data(contentsOf: base.appending(path: "Store/Index.plist")),
              let store = try? PropertyListSerialization.propertyList(from: storeData, format: nil) as? [String: Any],
              let all = store["AllSpacesAndDisplays"] as? [String: Any],
              let slot = (all["Desktop"] ?? all["Linked"]) as? [String: Any],
              let content = slot["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configData = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: configData, format: nil) as? [String: Any],
              let id = configuration["assetID"] as? String, id.hasPrefix("9A329B0F-"),
              let catalogData = try? Data(contentsOf: base.appending(path: "aerials/animated-wallpapers/entries.json")),
              let catalog = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
              let assets = catalog["assets"] as? [[String: Any]]
        else { return nil }
        return assets.first { $0["id"] as? String == id }?["localizedNameKey"] as? String
    }
}
