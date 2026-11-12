import AppKit
import ApplicationServices

// Standalone checks: no speech packages, audio capture, or synthetic paste events.
@main
@MainActor
struct TextInsertionChecks {
    private static var checks = 0

    private static func expect(_ condition: Bool, _ description: String) {
        precondition(condition, description)
        checks += 1
    }

    static func main() async {
        func verified(_ text: String, _ before: String?, _ after: String?,
                      _ selection: CFRange? = nil, terminal: Bool = false) -> Bool {
            TextInsertionVerification.confirmed(text: text, before: before, after: after,
                                                selection: selection, terminal: terminal)
        }

        expect(verified("hola", "", "hola", CFRange(location: 0, length: 0)), "Insert into an empty field")
        expect(verified("nuevo", "hola viejo", "hola nuevo", CFRange(location: 5, length: 5)), "Replace the selection")
        expect(verified("café", "😀 viejo", "😀 café", CFRange(location: 3, length: 5)), "Use UTF-16 selection offsets")
        expect(verified("word", "word word", "word", CFRange(location: 0, length: 9)), "Confirm replacement even when occurrence count falls")
        expect(!verified("text", "old", "old", CFRange(location: 0, length: 3)), "Unchanged text does not confirm a paste")
        expect(!verified("text", nil, "text"), "Missing before value cannot verify insertion")
        expect(!verified("text", "", nil), "Missing after value cannot verify insertion")
        expect(!verified("", "a", "b"), "Empty transcript cannot verify insertion")
        expect(!verified("text", "old", "different", CFRange(location: Int.max, length: Int.max)), "Reject overflowing selection")
        expect(!verified("text", "old", "different", CFRange(location: -1, length: 0)), "Reject negative selection")
        expect(!verified("text", "old", "different", CFRange(location: 1, length: -1)), "Reject negative selection length")
        expect(!verified("text", "text", "text unrelated"), "Existing transcript plus unrelated changes is not a paste")
        expect(verified("text", "text", "text text"), "Verify a repeated transcript by an additional occurrence")
        expect(verified("quiero saber", "$ ", "$ quiero\n saber", terminal: true), "Accept Terminal wrapping between words")
        expect(!verified("quiero saber", "quiero saber", "quiero saber\nstatus changed", terminal: true), "Do not confuse scrollback with newly inserted text")
        expect(verified("quiero saber", "quiero saber", "quiero saber\n$ quiero saber", terminal: true), "Repeated Terminal input is confirmed")
        expect(!verified("   ", "", "   ", terminal: true), "Terminal whitespace is not readback evidence")
        expect(!verified("secret", "$ ", "$ ", terminal: true), "No-echo input cannot be readback-confirmed")

        func canPaste(_ role: String?, window: Bool = true, selectedText: Bool = false,
                      editable: Bool = false, terminal: Bool = false) -> Bool {
            TextInsertionVerification.canAttemptPaste(role: role, selectedTextSettable: selectedText,
                                                       editable: editable, terminal: terminal, hasWindow: window)
        }
        expect(!canPaste(nil, window: false), "No window or focused control opens recovery instead of pasting into the desktop")
        for role in [kAXButtonRole, kAXStaticTextRole, kAXImageRole, kAXOutlineRole, kAXTableRole,
                     kAXRowRole, kAXMenuItemRole, kAXToolbarRole, "AXLink"] {
            expect(!canPaste(role), "A non-writing control must not receive paste: \(role)")
        }
        expect(canPaste(kAXTextFieldRole, window: false, selectedText: true), "A native input remains usable even without AX window metadata")
        expect(canPaste(kAXCellRole, editable: true), "An explicitly editable grid cell remains supported")
        expect(canPaste(kAXGroupRole), "Preserve custom editor paste without an application allowlist")
        expect(canPaste("AXWebArea"), "A web editor can still receive its normal paste events")
        expect(canPaste(nil), "Allow one fallback paste when a custom window hides its focused element")
        expect(canPaste(kAXTextAreaRole, terminal: true), "A recognized terminal session remains supported")
        expect(TextInsertionVerification.deliveryResult(terminal: false, focusRetained: false) == .unconfirmed,
               "An unverified paste whose destination lost focus opens the recovery window")
        expect(TextInsertionVerification.deliveryResult(terminal: false, focusRetained: true) == .pasteSubmitted,
               "An unreadable terminal/web input that kept focus counts as delivered")
        expect(TextInsertionVerification.deliveryResult(terminal: true, focusRetained: false) == .pasteSubmitted,
               "A positively identified Terminal session retains its explicit delivery status")

        expect(TextInsertionResult.inserted.succeeded, "Confirmed insertion succeeds")
        expect(TextInsertionResult.pasteSubmitted.succeeded, "Terminal delivery is distinct from readback confirmation")
        expect(!TextInsertionResult.unconfirmed.succeeded, "Unconfirmed normal-field paste retains recovery")
        expect(!TextInsertionResult.focusUnavailable.succeeded, "Missing original focus does not succeed")
        expect(!TextInsertionResult.unsupportedTarget.succeeded, "Unsupported controls do not succeed")
        expect(TextInserter.capture(application: nil) == nil, "No application has no destination")
        expect(TextInserter.capture(application: .current) == nil, "Never capture the dictation app itself")
        let noTarget = await TextInserter.insert("text", into: nil)
        expect(noTarget == .noTarget, "No destination cannot receive text")
        let ownTarget = TextInsertionTarget(application: .current, element: nil, window: nil, terminalSession: nil)
        let ownResult = await TextInserter.insert("text", into: ownTarget)
        expect(ownResult == .noTarget, "Never paste into the dictation app")
        let empty = await TextInserter.insert("", into: ownTarget)
        expect(empty == .noTarget, "Empty text is rejected before any paste")
        let task = Task { @MainActor in await TextInserter.insert("text", into: nil) }
        task.cancel()
        let cancelled = await task.value
        expect(cancelled == .cancelled, "Cancelled operations cannot paste")
        print("Passed \(checks) text insertion checks.")
    }
}
