import AppKit
import SwiftUI

enum DictationPhase: Equatable {
    case idle, preparing, recording, transcribing, polishing
}

// Only the recorder is replaced: mouse events exercise the real FlowBarView.
@MainActor
final class DictationController: ObservableObject {
    @Published var phase: DictationPhase = .recording
    @Published var barExpanded = false
    @Published var cancellationVisible = false
    @Published var canUndoCancellation = true
    var cancellationRemaining = 1.0
    let audioMeter = DictationMeter()
    var isHandsFree = true
    var stops: [Bool] = []
    var undoCount = 0

    func toggle() { }
    func stop(cancelled: Bool = false) {
        stops.append(cancelled)
        phase = .idle
        cancellationVisible = cancelled
    }
    func undoCancellation() { undoCount += 1 }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

@main
@MainActor
struct BarClickChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL:", message); exit(1) }
    }
    static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    static func click(_ x: CGFloat, _ y: CGFloat, in view: NSView, window: NSWindow) {
        let local = NSPoint(x: x, y: view.isFlipped ? view.bounds.height - y : y)
        let point = view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        settle(view)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = DictationBarPanel(contentRect: NSRect(x: -10000, y: -10000, width: 260, height: 96),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.orderFrontRegardless()
        check(window.frame.maxX < 0 && window.frame.maxY < 0, "Test window must remain offscreen")
        let recorder = DictationController()
        let view = DictationBarHostingView(recorder: recorder)
        window.contentView = view
        settle(view)
        check(!app.isActive, "Test clicks must occur while the app is inactive")
        check(view.acceptsFirstMouse(for: nil), "Accept first mouse click in the inactive panel")
        check(!window.isKeyWindow, "The dictation bar must not take keyboard focus")
        for phase in [DictationPhase.preparing, .recording, .transcribing, .polishing] {
            recorder.cancellationVisible = false
            recorder.phase = phase
            recorder.stops = []
            settle(view)
            click(view.bounds.midX - 36, 27, in: view, window: window)
            check(recorder.stops == [true], "Cancel must fire exactly once in \(phase)")
            check(recorder.cancellationVisible, "Cancel must show its notice")
        }
        recorder.cancellationVisible = false
        recorder.phase = .recording
        recorder.stops = []
        settle(view)
        click(view.bounds.midX + 36, 27, in: view, window: window)
        check(recorder.stops == [false], "Finish must fire exactly once")
        recorder.cancellationVisible = true
        settle(view)
        click(view.bounds.midX + 78, 36, in: view, window: window)
        check(recorder.undoCount == 1, "Undo must remain clickable")
        window.close()
        print("Passed inactive-panel first-click, four cancel phases, finish, and Undo checks.")
    }
}
