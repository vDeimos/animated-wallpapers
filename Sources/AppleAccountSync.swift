import AppKit
import ApplicationServices
import OSLog

enum AppleAccountSyncState: Equatable {
    case idle
    case permissionRequired
    case dragPermissionUnavailable
    case updating
    case saved
    case submitted
    case failed(String)
}

@MainActor
final class AppleAccountSync {
    private struct Request {
        let icon: URL
        let completion: (AppleAccountSyncState) -> Void
    }

    private static let settingsBundle = "com.apple.systempreferences"
    private static let accountSettingsBundle = "com.apple.systempreferences.AppleIDSettings"
    private static let accountSettings = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!
    static var usesAppProtectionOverride: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 27, minorVersion: 3, patchVersion: 0))
    }

    private static var accessibilitySettings: URL {
        let pane = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        return URL(string: usesAppProtectionOverride ? pane : pane + "?Privacy_Accessibility")!
    }
    private let log = Logger(subsystem: "local.gifpapers.animated-wallpapers", category: "account-sync")
    private var pending: Request?
    private var worker: Task<Void, Never>?

    static var isTrusted: Bool {
        if AXIsProcessTrusted() { return true }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundle)
            .first(where: { !$0.isTerminated }) else { return false }

        let element = AXUIElementCreateApplication(settings.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // macOS 27.3 also lets the user authorize one target app.
        return attribute(element, kAXWindowsAttribute) != nil
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(accessibilitySettings)
    }

    func submit(_ icon: URL, reopenSettings: Bool, completion: @escaping (AppleAccountSyncState) -> Void) {
        guard Self.isTrusted || reopenSettings else {
            completion(.permissionRequired)
            return
        }
        guard CGPreflightPostEventAccess() else {
            completion(.dragPermissionUnavailable)
            return
        }
        pending = Request(icon: icon, completion: completion)
        completion(.updating)
        guard worker == nil else { return }
        worker = Task {
            while let request = pending {
                pending = nil
                do {
                    let outcome = try await update(request.icon)
                    log.notice("Apple Account photo editor completed for \(request.icon.lastPathComponent, privacy: .public)")
                    request.completion(outcome)
                } catch is AccountPermissionRequired {
                    request.completion(.permissionRequired)
                } catch {
                    log.error("Apple Account photo update failed: \(error.localizedDescription, privacy: .public)")
                    request.completion(.failed(error.localizedDescription))
                }
            }
            worker = nil
        }
    }

    private func update(_ icon: URL) async throws -> AppleAccountSyncState {
        guard FileManager.default.isReadableFile(atPath: icon.path) else {
            throw SyncFailure("The matching icon could not be read.")
        }

        let workspace = NSWorkspace.shared
        let previous = workspace.frontmostApplication
        let libraryWindow = NSApp.windows.first { $0.isVisible && $0.title == "Animated Wallpapers" }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: Self.settingsBundle)
        guard workspace.open(Self.accountSettings) else {
            throw SyncFailure("Apple Account settings could not be opened.")
        }
        defer {
            libraryWindow?.orderFrontRegardless()
            if workspace.frontmostApplication?.bundleIdentifier == Self.settingsBundle,
               let previous, previous.bundleIdentifier != Self.settingsBundle {
                previous.activate()
            }
        }

        guard try await optionalWait(upTo: .seconds(3), { Self.isTrusted ? true : nil }) != nil else {
            throw AccountPermissionRequired()
        }
        let pane = try await wait(upTo: .seconds(8), failure: "Apple Account settings did not open.") {
            accountPane()
        }
        libraryWindow?.orderOut(nil)
        NSApp.yieldActivation(to: pane.application)
        pane.application.activate(from: .current, options: [.activateAllWindows])
        AXUIElementPerformAction(pane.window, kAXRaiseAction as CFString)

        guard pane.openSheets().isEmpty else {
            throw SyncFailure("Finish the open Apple Account photo edit and apply the wallpaper again.")
        }
        pane.revealHeader()
        let exposed = try await optionalWait(upTo: .seconds(3), {
            let targets = pane.dropTargets()
            return targets.isEmpty ? nil : targets
        })
        let targets = ((exposed ?? []) + pane.visibleHeaderTargets()).reduce(into: [CGPoint]()) { points, target in
            if !points.contains(where: { hypot($0.x - target.x, $0.y - target.y) < 16 }) { points.append(target) }
        }
        guard !targets.isEmpty else { throw SyncFailure("The Apple Account photo drop target was unavailable.") }
        log.notice("Found \(targets.count) Apple Account drop targets")
        var foundVisibleTarget = false

        for target in targets {
            guard try await optionalWait(upTo: .seconds(2), {
                targetBelongsToSettings(target, pid: pane.application.processIdentifier) ? true : nil
            }) != nil else { continue }
            foundVisibleTarget = true
            let accepted = try await dragFile(icon, to: target, settingsPID: pane.application.processIdentifier)
            if try await optionalWait(upTo: .seconds(3), { pane.photoEditor() }) != nil {
                // SwiftUI can replace the photo sheet and its controls while it loads the picture.
                let saveButton = try await wait(upTo: .seconds(12), failure: "The icon is in the Apple Account photo editor. Click Save to finish.") {
                    (accountPane() ?? pane).photoEditor()?.saveButton()
                }
                let action = AXUIElementPerformAction(saveButton, kAXPressAction as CFString)
                if action != .success {
                    try clickSaveButton(saveButton, in: pane)
                }
                _ = try await wait(upTo: .seconds(8), failure: "The Apple Account photo editor stayed open after Save.") {
                    (accountPane() ?? pane).photoEditor() == nil ? true : nil
                }
                return .saved
            }
            if accepted {
                // The Apple Account sidebar can accept a file directly without a crop sheet.
                log.notice("Apple Account sidebar accepted the picture directly")
                return .submitted
            }
        }
        if !foundVisibleTarget {
            throw SyncFailure("The Apple Account photo is covered by another window. Apply the wallpaper again to retry.")
        }
        throw SyncFailure("Apple Account settings did not accept the icon drop. Use Open Apple Account Picture to apply it manually.")
    }

    private func clickSaveButton(_ button: AXUIElement, in pane: AccountPane) throws {
        guard let visibleBounds = bounds(button),
              let editor = pane.photoEditor(), let ownButton = editor.saveButton(), CFEqual(ownButton, button),
              let source = CGEventSource(stateID: .privateState)
        else { throw SyncFailure("Apple’s photo editor is ready. Click Save to finish.") }

        let point = CGPoint(x: visibleBounds.midX, y: visibleBounds.midY)
        guard targetBelongsToSettings(point, pid: pane.application.processIdentifier) else {
            throw SyncFailure("The Apple Account Save button is covered by another window.")
        }
        let priorPointer = CGEvent(source: nil)?.location
        post(.leftMouseDown, at: point, source: source, tap: .cghidEventTap)
        post(.leftMouseUp, at: point, source: source, tap: .cghidEventTap)
        if let priorPointer { post(.mouseMoved, at: priorPointer, source: source, tap: .cghidEventTap) }
    }

    private func accountPane() -> AccountPane? {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundle)
            .first(where: { !$0.isTerminated }) else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.8)
        guard let window = elements(app, kAXWindowsAttribute).first(where: {
            normalized(string($0, kAXTitleAttribute)).contains("apple account") && bounds($0) != nil
        }) else { return nil }
        return AccountPane(application: application, window: window)
    }

    private func targetBelongsToSettings(_ point: CGPoint, pid: pid_t) -> Bool {
        guard let pane = accountPane(), pane.application.processIdentifier == pid,
              let frame = bounds(pane.window), frame.contains(point) else { return false }
        let root = AXIsProcessTrusted() ? AXUIElementCreateSystemWide() : AXUIElementCreateApplication(pid)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element) == .success,
           let element {
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success, isAccountWindowOwner(owner, settingsPID: pid) {
                return true
            }
        }

        // The first ordinary window at the target must still be Settings if the AX hit test is unavailable.
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let values = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: values), bounds.contains(point),
                  let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { continue }
            return isAccountWindowOwner(owner, settingsPID: pid)
        }
        return false
    }

    private func isAccountWindowOwner(_ owner: pid_t, settingsPID: pid_t) -> Bool {
        owner == settingsPID || NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == Self.accountSettingsBundle
    }

    private func dragFile(_ icon: URL, to target: CGPoint, settingsPID: pid_t) async throws -> Bool {
        let anchor = cocoaPoint(target)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) else {
            throw SyncFailure("The Apple Account photo was outside the visible screen.")
        }
        let display = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let side: CGFloat = 64
        let x = min(display.maxX - side, max(display.minX, anchor.x + 120))
        let proposedY = anchor.y > display.midY ? anchor.y - 135 : anchor.y + 75
        let y = min(display.maxY - side, max(display.minY, proposedY))
        let frame = NSRect(x: x, y: y, width: side, height: side)
        let source = FileDragSource(frame: NSRect(origin: .zero, size: frame.size), icon: icon)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = source
        panel.orderFrontRegardless()

        let start = quartzPoint(CGPoint(x: frame.midX, y: frame.midY))
        guard let eventSource = CGEventSource(stateID: .privateState) else {
            panel.orderOut(nil)
            throw SyncFailure("The Mac could not prepare the photo drag.")
        }
        let usesGlobalEvents = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        let tap: CGEventTapLocation = usesGlobalEvents ? .cghidEventTap : .cgSessionEventTap
        let settingsWindowNumber = windowNumber(at: target, for: settingsPID)
        let sourceWindowNumber = Int64(panel.windowNumber)
        if !usesGlobalEvents {
            guard let pane = accountPane(), pane.application.processIdentifier == settingsPID,
                  let settingsFrame = bounds(pane.window), settingsFrame.contains(start),
                  settingsFrame.contains(target) else {
                panel.orderOut(nil)
                throw SyncFailure("The icon and Apple Account picture could not fit in the same System Settings window.")
            }
        }
        log.notice("Photo drag uses \(usesGlobalEvents ? "HID" : "window-verified session", privacy: .public) events")
        let oldPointer = usesGlobalEvents ? CGEvent(source: nil)?.location : nil
        var held = false
        var pointer = start
        defer {
            if held {
                post(.leftMouseUp, at: pointer, source: eventSource, tap: tap, windowNumber: settingsWindowNumber)
            }
            panel.orderOut(nil)
            if let oldPointer {
                post(.mouseMoved, at: oldPointer, source: eventSource, tap: tap)
            }
        }
        try await Task.sleep(for: .milliseconds(110))
        guard !CGEventSource.buttonState(.hidSystemState, button: .left) else {
            throw SyncFailure("The mouse button was busy. Apply the wallpaper again to retry.")
        }
        post(.mouseMoved, at: start, source: eventSource, tap: tap, windowNumber: sourceWindowNumber)
        try await Task.sleep(for: .milliseconds(35))
        post(.leftMouseDown, at: start, source: eventSource, tap: tap, windowNumber: sourceWindowNumber)
        held = true
        _ = try await wait(upTo: .seconds(1), failure: "macOS did not allow the mouse events needed for the Apple Account icon drag under the current permission.") {
            source.requestedDrag ? true : nil
        }
        for step in 1...17 {
            let part = CGFloat(step) / 17
            pointer = CGPoint(x: start.x + (target.x - start.x) * part,
                              y: start.y + (target.y - start.y) * part)
            post(.leftMouseDragged, at: pointer, source: eventSource, tap: tap, windowNumber: settingsWindowNumber)
            try await Task.sleep(for: .milliseconds(24))
        }
        try await Task.sleep(for: .milliseconds(170))
        guard targetBelongsToSettings(target, pid: settingsPID) else {
            post(.leftMouseUp, at: start, source: eventSource, tap: tap, windowNumber: settingsWindowNumber)
            held = false
            throw SyncFailure("The system photo drop target changed during the drag.")
        }
        post(.leftMouseUp, at: target, source: eventSource, tap: tap, windowNumber: settingsWindowNumber)
        held = false
        let operation = try await optionalWait(upTo: .seconds(2), { source.result })
        log.notice("Drag began: \(source.started). System photo drop operation: \(operation?.rawValue ?? 0).")
        return operation == .copy
    }

    private func windowNumber(at point: CGPoint, for pid: pid_t) -> Int64? {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let values = $0[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: values),
                  frame.contains(point)
            else { return false }
            return true
        }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.int64Value }
    }

    private func post(_ type: CGEventType, at point: CGPoint, source: CGEventSource, tap: CGEventTapLocation,
                      windowNumber: Int64? = nil) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []
        if type == .leftMouseDown || type == .leftMouseUp {
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        if let windowNumber {
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowNumber)
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowNumber)
        }
        event?.post(tap: tap)
    }

    private func cocoaPoint(_ point: CGPoint) -> CGPoint {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: point.x, y: height - point.y)
    }

    private func quartzPoint(_ point: CGPoint) -> CGPoint { cocoaPoint(point) }
}

private struct AccountPermissionRequired: Error {}

private struct SyncFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private final class FileDragSource: NSView, NSDraggingSource {
    let icon: URL
    let artwork: NSImage
    private(set) var requestedDrag = false
    private(set) var started = false
    private(set) var result: NSDragOperation?

    init(frame: NSRect, icon: URL) {
        self.icon = icon
        artwork = NSImage(contentsOf: icon) ?? NSWorkspace.shared.icon(forFile: icon.path)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        artwork.draw(in: bounds.insetBy(dx: 5, dy: 5))
    }

    override func mouseDown(with event: NSEvent) {
        guard !requestedDrag else { return }
        requestedDrag = true
        let file = NSDraggingItem(pasteboardWriter: icon as NSURL)
        file.setDraggingFrame(bounds.insetBy(dx: 5, dy: 5), contents: artwork)
        let session = beginDraggingSession(with: [file], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        started = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        result = operation
    }
}

private struct AccountPane {
    let application: NSRunningApplication
    let window: AXUIElement

    func dropTargets() -> [CGPoint] {
        guard let frame = bounds(window) else { return [] }
        let items = descendants(window)
        let sidebarRow = items.first { item in
            guard string(item, kAXRoleAttribute) == kAXRowRole,
                  let row = bounds(item),
                  row.minX < frame.minX + 110, row.midY < frame.minY + 215
            else { return false }
            let descriptions = [item] + elements(item, kAXChildrenAttribute)
            return descriptions.contains { element in
                [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].contains { attribute in
                    normalized(string(element, attribute)).contains("apple account")
                }
            }
        }
        let portrait = items.first { item in
            guard string(item, kAXRoleAttribute) == kAXImageRole, let image = bounds(item) else { return false }
            return image.width > 65 && image.width < 125 && abs(image.width - image.height) < 4
                && image.midY < frame.minY + 270 && image.minX > frame.minX + 170
        }
        var targets: [CGPoint] = []
        if let sidebarRow, let row = bounds(sidebarRow) {
            targets.append(CGPoint(x: row.minX + 25, y: row.midY))
        }
        if let portrait, let image = bounds(portrait) {
            targets.append(CGPoint(x: image.midX, y: image.midY))
        }
        return targets
    }

    func revealHeader() {
        guard let windowFrame = bounds(window) else { return }
        for bar in descendants(window) where string(bar, kAXRoleAttribute) == kAXScrollBarRole {
            guard let frame = bounds(bar), frame.height > frame.width,
                  frame.minX > windowFrame.minX, frame.maxX <= windowFrame.maxX + 2
            else { continue }
            if let value = attribute(bar, kAXValueAttribute) as? NSNumber, value.doubleValue > 0 {
                AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: 0))
            }
        }
    }

    func visibleHeaderTargets() -> [CGPoint] {
        guard let frame = bounds(window),
              normalized(string(window, kAXTitleAttribute)) == "apple account",
              frame.width >= 570, frame.height >= 430 else { return [] }

        // In this pane the portrait is centered in the detail column, below the title bar.
        let split = descendants(window).first { string($0, kAXRoleAttribute) == kAXSplitterRole }
        let width = split.flatMap { attribute($0, kAXValueAttribute) as? NSNumber }?.doubleValue
        let sidebarWidth = CGFloat(width.flatMap { (155...330).contains($0) ? $0 : nil } ?? 231.5)
        return [
            CGPoint(x: frame.minX + (sidebarWidth + frame.width) / 2, y: frame.minY + 124),
            CGPoint(x: frame.minX + 35, y: frame.minY + 121)
        ]
    }

    func openSheets() -> [AXUIElement] {
        let app = AXUIElementCreateApplication(application.processIdentifier)
        let focused = attribute(app, kAXFocusedWindowAttribute).flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? [$0 as! AXUIElement] : nil
        } ?? []
        return (elements(window, "AXSheets") + elements(window, kAXChildrenAttribute)
                + elements(app, kAXWindowsAttribute) + focused)
            .filter { string($0, kAXRoleAttribute) == kAXSheetRole }
    }

    func photoEditor() -> PhotoEditor? {
        openSheets().first { sheet in
            descendants(sheet).contains { element in
                [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute].contains { attribute in
                    let value = normalized(string(element, attribute))
                    return value.contains("avatar preview cropping") || value.contains("avatar zoom slider")
                }
            }
        }.map(PhotoEditor.init)
    }
}

private struct PhotoEditor {
    let sheet: AXUIElement
    func saveButton() -> AXUIElement? {
        var controls = descendants(sheet).filter { string($0, kAXRoleAttribute) == kAXButtonRole }
        if let defaultButton = attribute(sheet, kAXDefaultButtonAttribute),
           CFGetTypeID(defaultButton) == AXUIElementGetTypeID() {
            controls.insert(defaultButton as! AXUIElement, at: 0)
        }
        if let labeled = controls.first(where: { labels($0).contains("save") && enabled($0) }) {
            return labeled
        }

        // Some versions expose the primary control through its footer position instead of an AX title.
        guard let cancel = controls.first(where: { labels($0).contains("cancel") }),
              let cancelFrame = bounds(cancel) else { return nil }
        let candidates = controls.filter { candidate in
            guard enabled(candidate), let frame = bounds(candidate) else { return false }
            return frame.minX > cancelFrame.maxX && frame.minX < cancelFrame.maxX + 40
                && abs(frame.midY - cancelFrame.midY) < 9 && abs(frame.height - cancelFrame.height) < 10
        }
        let unique = Set(candidates)
        return unique.count == 1 ? unique.first : nil
    }

    private func labels(_ control: AXUIElement) -> Set<String> {
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, "AXLabel"]
        return Set(([control] + elements(control, kAXChildrenAttribute)).flatMap { element in
            names.map { normalized(string(element, $0)) }
        }.filter { !$0.isEmpty })
    }

    private func enabled(_ control: AXUIElement) -> Bool {
        (attribute(control, kAXEnabledAttribute) as? NSNumber)?.boolValue != false
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
}

private func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

private func normalized(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
}

private func bounds(_ item: AXUIElement) -> CGRect? {
    if let rawFrame = attribute(item, "AXFrame"), CFGetTypeID(rawFrame) == AXValueGetTypeID() {
        var frame = CGRect.zero
        if AXValueGetValue(rawFrame as! AXValue, .cgRect, &frame), frame.width > 0, frame.height > 0 {
            return frame
        }
    }
    guard let rawPosition = attribute(item, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          let rawSize = attribute(item, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
          AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0
    else { return nil }
    return CGRect(origin: origin, size: size)
}

private func descendants(_ root: AXUIElement) -> [AXUIElement] {
    func children(_ element: AXUIElement) -> [AXUIElement] {
        let ordinary = elements(element, kAXChildrenAttribute)
        return ordinary.isEmpty ? elements(element, kAXVisibleChildrenAttribute) : ordinary
    }
    var queue = children(root)
    var visited = Set<AXUIElement>()
    var result: [AXUIElement] = []
    var index = 0
    while index < queue.count && result.count < 550 {
        let node = queue[index]
        index += 1
        if visited.insert(node).inserted {
            result.append(node)
            queue.append(contentsOf: children(node))
        }
    }
    return result
}

@MainActor
private func optionalWait<T>(upTo timeout: Duration, _ value: () -> T?) async throws -> T? {
    let end = ContinuousClock.now + timeout
    repeat {
        if let result = value() { return result }
        try await Task.sleep(for: .milliseconds(110))
    } while ContinuousClock.now < end
    return nil
}

@MainActor
private func wait<T>(upTo timeout: Duration, failure: String, _ value: () -> T?) async throws -> T {
    guard let result = try await optionalWait(upTo: timeout, value) else { throw SyncFailure(failure) }
    return result
}
