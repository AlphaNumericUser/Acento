import AppKit
import Carbon

@main
struct ShortcutCaptureChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = KeyCaptureNSView()
        var captured: [(Int, Int, String)] = []
        view.onCapture = { captured.append(($0, $1, $2)) }
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func event(_ key: UInt16, _ flags: NSEvent.ModifierFlags = [], _ text: String = "", type: NSEvent.EventType = .keyDown, repeat repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: text,
                             charactersIgnoringModifiers: text, isARepeat: repeating, keyCode: key)!
        }
        for (key, text, label) in [(UInt16(0), "a", "A"), (49, " ", "Space"),
                                   (53, "\u{1b}", "Escape"), (48, "\t", "Tab"),
                                   (36, "\r", "Return"), (97, "", "F6"), (51, "\u{7f}", "⌫"),
                                   (123, "", "←")] {
            view.keyDown(with: event(key, [], text))
            expect(captured.last?.0 == Int(key) && captured.last?.1 == 0 && captured.last?.2 == label,
                   "Single key must be captured and named: \(label)")
        }
        view.keyDown(with: event(2, [.command, .shift], "d"))
        expect(captured.last?.1 == Int(cmdKey | shiftKey) && captured.last?.2 == "⇧ + ⌘ + D", "Command + Shift + D")
        let count = captured.count
        view.keyDown(with: event(2, [.command, .shift], "d", repeat: true))
        expect(captured.count == count, "Ignore held-key repeats")
        for (key, mask) in ShortcutKey.deviceMasks where key != 57 {
            let before = captured.count
            view.flagsChanged(with: event(key, NSEvent.ModifierFlags(rawValue: mask), type: .flagsChanged))
            expect(captured.count == before, "Wait for modifier release")
            view.flagsChanged(with: event(key, [], type: .flagsChanged))
            expect(captured.last?.0 == Int(key) && captured.last?.1 == 0 && captured.last?.2 == ShortcutKey.modifierNames[key],
                   "Capture left/right modifier or Fn on release")
        }
        view.flagsChanged(with: event(55, NSEvent.ModifierFlags(rawValue: 0x08 | NSEvent.ModifierFlags.command.rawValue), type: .flagsChanged))
        view.keyDown(with: event(2, [.command], "d"))
        view.flagsChanged(with: event(55, [], type: .flagsChanged))
        expect(captured.last?.0 == 2 && captured.last?.2 == "⌘ + D", "Modifier release must not replace a captured chord")
        view.flagsChanged(with: event(55, NSEvent.ModifierFlags(rawValue: 0x08 | NSEvent.ModifierFlags.command.rawValue), type: .flagsChanged))
        view.flagsChanged(with: event(56, NSEvent.ModifierFlags(rawValue: 0x0a | NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue), type: .flagsChanged))
        view.flagsChanged(with: event(56, [.command], type: .flagsChanged))
        expect(captured.last?.0 == 56 && captured.last?.1 == Int(cmdKey), "Modifier-only chord stores the other modifiers")
        view.keyDown(with: event(97, [.function]))
        expect(captured.last?.1 == 0 && captured.last?.2 == "F6", "Function key flag does not falsely require Fn")
        view.keyDown(with: event(2, [.function], "d"))
        expect(captured.last?.1 == ShortcutKey.fnModifier && captured.last?.2 == "Fn + D", "Fn chord must not become plain D")
        view.flagsChanged(with: event(57, [.capsLock], type: .flagsChanged))
        expect(captured.last?.0 == 57 && captured.last?.2 == "Caps Lock", "Caps Lock is assignable")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        window.contentView = root
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        root.addSubview(view)
        let commandQ = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "q",
                                       charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
        NSApp.sendEvent(commandQ)
        expect(captured.last?.2 == "⌘ + Q", "Local monitor captures application key equivalents")
        let beforeOutside = captured.count
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 50), modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(outside)
        NSApp.sendEvent(commandQ)
        expect(captured.count == beforeOutside, "Clicking outside stops shortcut capture")
        let inside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 50), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.sendEvent(inside)
        NSApp.sendEvent(commandQ)
        expect(captured.count == beforeOutside + 1, "Clicking the capture field rearms it")
        view.removeFromSuperview()
        NSApp.sendEvent(commandQ)
        expect(captured.count == beforeOutside + 1, "Removing the field removes its keyboard monitor")
        window.close()
        print("Passed \(checks) production shortcut capture checks.")
    }
}
