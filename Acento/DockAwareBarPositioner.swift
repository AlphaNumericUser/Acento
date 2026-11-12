import AppKit
import CoreGraphics

nonisolated enum DictationBarLayout {
    static func appKitFrame(from windowFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: windowFrame.minX, y: primaryScreenTop - windowFrame.maxY,
               width: windowFrame.width, height: windowFrame.height)
    }

    static func origin(screen: CGRect, panelSize: CGSize, dockFrames: [CGRect]) -> CGPoint {
        let dockTop = dockFrames.compactMap { frame -> CGFloat? in
            let visible = frame.intersection(screen)
            guard !visible.isNull, visible.height > 12,
                  frame.width > frame.height * 2,
                  visible.width > 100,
                  visible.height < screen.height / 3,
                  visible.minY <= screen.minY + 24,
                  visible.minX <= screen.midX, visible.maxX >= screen.midX else { return nil }
            return visible.maxY
        }.max() ?? screen.minY
        return CGPoint(x: screen.midX - panelSize.width / 2, y: dockTop + 8)
    }
}

nonisolated struct DockWindowGeometry: Sendable {
    var frame: CGRect // Core Graphics coordinates until applied on MainActor.
    let layer: Int
    let isDock: Bool
    let alpha: Double
}

@MainActor
final class DockAwareBarPositioner {
    private weak var panel: NSPanel?
    private var displayID: CGDirectDisplayID?
    private var timer: Timer?
    private var animationTimer: Timer?
    private let queryQueue = DispatchQueue(label: "com.useacento.acento.dock-geometry", qos: .utility)
    private let windowProvider: @Sendable () -> [DockWindowGeometry]
    private let mouseLocation: @MainActor () -> NSPoint
    private var pendingSampleID: UUID?
    private var resampleRequested = false
    private var immediateRequested = false
    private var running = false
    private var destination = CGPoint.zero
    private var lastSample: TimeInterval = 0
    private var animationOrigin: CGPoint?
    private var animationStarted: TimeInterval = 0
    private struct ScreenPositions {
        var screenFrame: CGRect
        var panelSize: CGSize
        var bottom: CGPoint
        var aboveDock: CGPoint
    }
    private var positions: [CGDirectDisplayID: ScreenPositions] = [:]
    private var fullScreenState: [CGDirectDisplayID: Bool] = [:]

    init(panel: NSPanel,
         windowProvider: @escaping @Sendable () -> [DockWindowGeometry] = { DockAwareBarPositioner.readWindows() },
         mouseLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation }) {
        self.panel = panel
        self.windowProvider = windowProvider
        self.mouseLocation = mouseLocation
    }

    func start() {
        guard !running else { return }
        running = true
        if panel?.isVisible == true {
            requestReposition()
        } else {
            repositionImmediately()
        }
        scheduleMonitor(after: 0.5)
    }

    private func scheduleMonitor(after interval: TimeInterval) {
        timer?.invalidate()
        guard running else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.monitor()
            }
        }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        animationOrigin = nil
        pendingSampleID = nil
        resampleRequested = false
        immediateRequested = false
    }

    func repositionImmediately() {
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation(), $0.frame, false) }
            ?? NSScreen.main
        displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // Use known screen geometry immediately; WindowServer queries are asynchronous.
        if let panel, let screen {
            destination = DictationBarLayout.origin(screen: screen.frame, panelSize: panel.frame.size, dockFrames: [])
            panel.setFrameOrigin(destination)
        }
        sampleDestination(immediate: true)
    }

    func requestReposition() {
        guard panel?.isVisible == true else {
            repositionImmediately()
            return
        }
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation(), $0.frame, false) }
            ?? NSScreen.main
        displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // Resample immediately without hiding the panel or restarting its movement.
        sampleDestination()
    }

    private func sampleDestination(immediate: Bool = false) {
        guard pendingSampleID == nil else {
            resampleRequested = true
            immediateRequested = immediateRequested || immediate
            return
        }
        let id = UUID()
        pendingSampleID = id
        let provider = windowProvider
        queryQueue.async { [weak self] in
            let windows = provider()
            Task { @MainActor [weak self] in
                guard let self, self.pendingSampleID == id else { return }
                self.pendingSampleID = nil
                guard self.running, self.panel?.isVisible == true else { return }
                if self.resampleRequested {
                    let immediately = self.immediateRequested || immediate
                    self.resampleRequested = false
                    self.immediateRequested = false
                    self.sampleDestination(immediate: immediately)
                } else {
                    self.apply(windows, immediate: immediate)
                }
            }
        }
    }

    nonisolated private static func readWindows() -> [DockWindowGeometry] {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return DockWindowGeometry(frame: frame,
                layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                isDock: window[kCGWindowOwnerName as String] as? String == "Dock",
                alpha: (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    private func apply(_ snapshot: [DockWindowGeometry], immediate: Bool) {
        guard let panel,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              }) ?? NSScreen.main else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let windows = snapshot.map { window in
            var converted = window
            converted.frame = DictationBarLayout.appKitFrame(from: window.frame, primaryScreenTop: primaryTop)
            return converted
        }
        let dockFrames = windows.compactMap { window -> CGRect? in
            guard window.isDock, window.layer >= 0, window.alpha > 0.05 else { return nil }
            return window.frame
        }
        var frames = dockFrames
        // A fixed Dock reserves screen space even when its window metadata is unavailable.
        // Full-screen windows suppress that reservation, so do not apply it over them.
        let fullScreenFrames = windows.compactMap { window -> CGRect? in
            guard window.layer == 0 else { return nil }
            let frame = window.frame
            // During a three-finger swipe, full-screen windows slide horizontally.
            // Their size still identifies them; requiring them to cover the screen
            // mistakes the intermediate frames for the desktop and raises the bar.
            guard frame.width >= screen.frame.width - 2
                && frame.intersection(screen.frame).width > 1
                && frame.minY <= screen.frame.minY + 1 && frame.maxY >= screen.frame.maxY - 1 else { return nil }
            return frame
        }
        let hasFullScreenWindow = !fullScreenFrames.isEmpty
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let autoHides = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        let reservedBottom = screen.visibleFrame.minY - screen.frame.minY
        let now = ProcessInfo.processInfo.systemUptime
        lastSample = now
        // Sliding windows describe a transition, not a temporary desktop. Keep
        // drawing at the existing position until the new Space is observable.
        let isSliding = fullScreenFrames.contains {
            abs($0.minX - screen.frame.minX) > 2 || abs($0.maxX - screen.frame.maxX) > 2
        }
        if isSliding && !immediate { return }
        let hasStableNormalWindow = windows.contains { window in
            guard window.layer == 0 else { return false }
            let frame = window.frame
            return frame.width > 200 && frame.height > 100
                && screen.frame.insetBy(dx: -2, dy: -2).contains(frame)
                && frame.height < screen.frame.height - 2
        }
        let visibleDock = DictationBarLayout.origin(screen: screen.frame, panelSize: panel.frame.size,
            dockFrames: dockFrames).y > screen.frame.minY + 9
        let desktopFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        // A missing window during composition is not evidence that a Dock appeared.
        if !immediate && !hasFullScreenWindow && !hasStableNormalWindow && !visibleDock
            && !desktopFocused && fullScreenState[id] == true { return }
        fullScreenState[id] = hasFullScreenWindow
        let needsFallback = !autoHides && !hasFullScreenWindow && reservedBottom > 12
        if needsFallback {
            frames.append(CGRect(x: screen.frame.minX, y: screen.frame.minY,
                                  width: screen.frame.width, height: reservedBottom))
        }
        let bottom = DictationBarLayout.origin(screen: screen.frame, panelSize: panel.frame.size, dockFrames: [])
        let dockPosition = DictationBarLayout.origin(screen: screen.frame, panelSize: panel.frame.size, dockFrames: frames)
        if positions[id]?.screenFrame != screen.frame || positions[id]?.panelSize != panel.frame.size {
            let reserved = reservedBottom > 12 ? [CGRect(x: screen.frame.minX, y: screen.frame.minY,
                width: screen.frame.width, height: reservedBottom)] : []
            positions[id] = ScreenPositions(screenFrame: screen.frame, panelSize: panel.frame.size,
                bottom: bottom, aboveDock: DictationBarLayout.origin(screen: screen.frame,
                    panelSize: panel.frame.size, dockFrames: reserved))
        }
        let dockVisible = dockPosition.y > bottom.y + 1
        if dockVisible, positions[id]?.aboveDock != dockPosition {
            positions[id]?.aboveDock = dockPosition
        }
        guard let cached = positions[id] else { return }
        let proposed = dockVisible ? cached.aboveDock : cached.bottom
        if immediate {
            destination = proposed
            animationOrigin = nil
            panel.setFrameOrigin(destination)
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        if abs(proposed.x - destination.x) < 1 && abs(proposed.y - destination.y) < 1 {
            return
        }
        destination = proposed
        animationOrigin = panel.frame.origin
        animationStarted = now
        startAnimation()
    }

    private func monitor() {
        guard let panel, panel.isVisible else { stop(); return }
        let screen = panel.screen ?? NSScreen.main
        let pointer = mouseLocation()
        let nearDock = screen.map {
            $0.frame.contains(pointer) && pointer.y < $0.frame.minY + 200
        } ?? false
        let now = ProcessInfo.processInfo.systemUptime
        if pendingSampleID == nil, now - lastSample >= (nearDock ? 0.1 : 2) {
            sampleDestination()
        }
        scheduleMonitor(after: nearDock ? 0.1 : 0.5)
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func animate() {
        guard let panel, panel.isVisible, let origin = animationOrigin else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : min(1, max(0, (now - animationStarted) / 0.32))
        // Smooth acceleration and deceleration, with zero velocity at both endpoints.
        let fraction = progress * progress * progress * (progress * (progress * 6 - 15) + 10)
        panel.setFrameOrigin(CGPoint(x: origin.x + (destination.x - origin.x) * fraction,
                                    y: origin.y + (destination.y - origin.y) * fraction))
        if progress >= 1 {
            animationOrigin = nil
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }
}
