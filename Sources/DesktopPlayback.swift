import AppKit
import AVFoundation
import OSLog

private let playbackLog = Logger(subsystem: "local.gifpapers.animated-wallpapers", category: "playback")

@MainActor
final class DesktopSurface {
    private final class DesktopWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor
    private final class Playback {
        let player = AVQueuePlayer()
        let layer: AVPlayerLayer
        let looper: AVPlayerLooper
        var observers: [NSKeyValueObservation] = []

        init(asset: AVURLAsset, bounds: CGRect) {
            player.isMuted = true
            layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        }

        func tearDown() {
            observers.removeAll()
            layer.removeFromSuperlayer()
            looper.disableLooping()
            player.pause()
            player.removeAllItems()
        }
    }

    private let window: NSWindow
    private let canvas = NSView()
    private var active: Playback?
    private var pending: Playback?
    private var isPaused = false
    private var sessionInactive = false

    init(screen: NSScreen) {
        window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false)
        window.title = "Animated Wallpaper"
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.animationBehavior = .none
        canvas.wantsLayer = true
        window.contentView = canvas
        resize(to: screen)
    }

    func resize(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
    }

    func present(_ asset: AVURLAsset, onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
        guard let backingLayer = canvas.layer else {
            onError("Could not create the desktop video layer.")
            return
        }
        pending?.tearDown()
        let next = Playback(asset: asset, bounds: backingLayer.bounds)
        pending = next
        backingLayer.insertSublayer(next.layer, at: 0)
        next.observers.append(next.layer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self, weak next] _, _ in
            Task { @MainActor in
                guard let self, let next, self.pending === next, next.layer.isReadyForDisplay else { return }
                self.active?.tearDown()
                self.active = next
                self.pending = nil
                self.window.orderBack(nil)
                self.updatePlayback()
                onReady()
                let name = asset.url.lastPathComponent
                playbackLog.notice("Desktop frame ready for \(name, privacy: .public) at window level \(self.window.level.rawValue)")
            }
        })
        next.observers.append(next.looper.observe(\.status, options: [.initial, .new]) {
            [weak self, weak next] _, _ in
            Task { @MainActor in
                guard let self, let next, next.looper.status == .failed else { return }
                guard self.pending === next || self.active === next else { return }
                let message = next.looper.error?.localizedDescription ?? "Wallpaper playback failed."
                if self.pending === next { self.pending = nil }
                if self.active === next {
                    self.active = nil
                    self.window.orderOut(nil)
                }
                next.tearDown()
                playbackLog.error("Wallpaper playback failed: \(message, privacy: .public)")
                onError(message)
            }
        })
        next.observers.append(next.looper.observe(\.loopCount, options: .new) {
            _, change in
            guard change.newValue == 1 else { return }
            let name = asset.url.lastPathComponent
            playbackLog.notice("Completed first loop of \(name, privacy: .public)")
        })
        updatePlayback()
    }

    func setPaused(_ paused: Bool, sessionInactive: Bool) {
        isPaused = paused
        self.sessionInactive = sessionInactive
        updatePlayback()
    }

    private func updatePlayback() {
        if isPaused || sessionInactive {
            active?.player.pause()
        } else {
            active?.player.play()
        }
        // A newly selected item needs its first frame even if the user paused playback.
        if sessionInactive {
            pending?.player.pause()
        } else {
            pending?.player.play()
        }
    }

    func close() {
        active?.tearDown()
        pending?.tearDown()
        window.close()
    }
}
