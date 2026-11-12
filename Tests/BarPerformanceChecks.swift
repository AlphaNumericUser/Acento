import AppKit
import Combine

nonisolated private final class WindowProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var maximumActive = 0
    private var onMain = false
    var delay: TimeInterval = 0
    var windows: [DockWindowGeometry] = []

    func sample() -> [DockWindowGeometry] {
        lock.lock()
        count += 1
        active += 1
        maximumActive = max(maximumActive, active)
        onMain = onMain || Thread.isMainThread
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        active -= 1
        lock.unlock()
        return windows
    }

    var stats: (count: Int, maximumActive: Int, onMain: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, maximumActive, onMain)
    }
}

@MainActor
private final class TrackingPanel: NSPanel {
    var moves = 0
    override func setFrameOrigin(_ point: NSPoint) {
        moves += 1
        super.setFrameOrigin(point)
    }
}

@main
@MainActor
struct BarPerformanceChecks {
    private static var checks = 0

    private static func expect(_ condition: Bool, _ description: String) {
        precondition(condition, description)
        checks += 1
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let meter = DictationMeter()
        var notifications = 0
        let subscription = meter.objectWillChange.sink { notifications += 1 }
        meter.reset()
        expect(notifications == 0, "Resetting an idle meter does not publish redundant UI work")
        for _ in 0..<60 { meter.update(0.8) }
        expect(notifications == 60, "One waveform notification per accepted audio update")
        expect(meter.levels.count == 10 && meter.levels.allSatisfy { $0 >= 0 && $0 <= 1 }, "Waveform stays bounded")
        meter.reset()
        expect(meter.levels.allSatisfy { $0 == 0 }, "Stopping clears the waveform")
        meter.reset()
        expect(notifications == 61, "Repeated stop does not invalidate the waveform")
        withExtendedLifetime(subscription) { }

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 260, height: 96)
        let bottom = DictationBarLayout.origin(screen: screen, panelSize: size, dockFrames: [])
        expect(bottom == CGPoint(x: 590, y: 8), "Center the bar at the bottom when Dock is absent")
        let above = DictationBarLayout.origin(screen: screen, panelSize: size,
            dockFrames: [CGRect(x: 200, y: 0, width: 1040, height: 80)])
        expect(above == CGPoint(x: 590, y: 88), "Keep the bar above a bottom Dock")
        expect(DictationBarLayout.origin(screen: screen, panelSize: size,
            dockFrames: [CGRect(x: 0, y: 0, width: 70, height: 900)]) == bottom, "A side Dock does not raise the bar")

        guard let display = NSScreen.main else { fatalError("A display is required for panel checks") }
        let panel = TrackingPanel(contentRect: NSRect(x: -10000, y: -10000, width: 260, height: 96),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0 // Exercise WindowServer positioning without a visible test overlay.
        panel.orderFrontRegardless()
        let provider = WindowProvider()
        let pointer = NSPoint(x: display.frame.midX, y: display.frame.maxY - 40)
        let positioner = DockAwareBarPositioner(panel: panel, windowProvider: { provider.sample() }, mouseLocation: { pointer })
        positioner.start()
        settle(0.7)
        let movesAfterSettling = panel.moves
        let samplesAfterSettling = provider.stats.count
        settle(2.3)
        let idleSamples = provider.stats.count - samplesAfterSettling
        expect(idleSamples <= 2, "A stationary bar does not query all windows 20 times per second")
        expect(panel.moves == movesAfterSettling, "A stationary bar has no ongoing animation frames")
        expect(!provider.stats.onMain, "Window queries never run on the main thread")
        positioner.stop()
        let stoppedCount = provider.stats.count
        settle(0.65)
        expect(provider.stats.count == stoppedCount, "Hiding the bar stops periodic queries")

        let slow = WindowProvider()
        slow.delay = 0.2
        let slowPositioner = DockAwareBarPositioner(panel: panel, windowProvider: { slow.sample() }, mouseLocation: { pointer })
        let started = ProcessInfo.processInfo.systemUptime
        slowPositioner.start()
        for _ in 0..<20 { slowPositioner.requestReposition() }
        expect(ProcessInfo.processInfo.systemUptime - started < 0.15, "A slow WindowServer query does not block bar requests")
        settle(0.55)
        expect(slow.stats.count <= 2 && slow.stats.maximumActive == 1, "Coalesce repeated requests without concurrent query floods")
        slowPositioner.stop()

        let stale = WindowProvider()
        stale.delay = 0.2
        let stalePositioner = DockAwareBarPositioner(panel: panel, windowProvider: { stale.sample() }, mouseLocation: { pointer })
        stalePositioner.start()
        stalePositioner.stop()
        let movesBeforeStaleResult = panel.moves
        settle(0.35)
        expect(panel.moves == movesBeforeStaleResult, "An in-flight query cannot move a stopped bar")
        panel.close()
        print("Passed \(checks) meter, Dock layout, idle activity, coalescing, and UI responsiveness checks (\(idleSamples) idle queries in 2.3 s).")
    }
}
