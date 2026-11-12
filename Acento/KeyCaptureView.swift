import AppKit
import SwiftUI

struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (Int, Int, String) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        view.onCapture = onCapture
    }
}

final class KeyCaptureNSView: NSView {
    var onCapture: ((Int, Int, String) -> Void)?
    private var candidate: (key: UInt16, modifiers: Int)?
    private var monitor: Any?
    private var armed = true
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        // Capture before menu shortcuts and SwiftUI's Escape action can consume the key.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .leftMouseDown {
                self.armed = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                self.candidate = nil
                if self.armed { window.makeFirstResponder(self) }
                else if window.firstResponder === self { window.makeFirstResponder(nil) }
                return event
            }
            guard self.armed else { return event }
            if event.type == .keyDown { self.keyDown(with: event) }
            else { self.flagsChanged(with: event) }
            return nil
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    override func mouseDown(with event: NSEvent) {
        armed = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard armed else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        candidate = nil
        let modifiers = ShortcutKey.capturedModifiers(event)
        onCapture?(Int(event.keyCode), modifiers,
                   ShortcutKey.label(key: event.keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers ?? ""))
    }

    override func flagsChanged(with event: NSEvent) {
        guard armed else { super.flagsChanged(with: event); return }
        guard let mask = ShortcutKey.deviceMasks[event.keyCode] else { return }
        if event.modifierFlags.rawValue & mask != 0 || event.keyCode == 57 {
            let modifiers = ShortcutKey.capturedModifiers(event)
            candidate = (event.keyCode, modifiers)
            if event.keyCode == 57 {
                onCapture?(57, modifiers, ShortcutKey.label(key: 57, modifiers: modifiers, characters: ""))
                candidate = nil
            }
        } else if let candidate, candidate.key == event.keyCode {
            onCapture?(Int(candidate.key), candidate.modifiers,
                       ShortcutKey.label(key: candidate.key, modifiers: candidate.modifiers, characters: ""))
            self.candidate = nil
        }
    }
}
