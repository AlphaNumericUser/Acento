import AppKit
import ApplicationServices
import OSLog

enum TextInsertionResult: Equatable {
    case inserted, pasteSubmitted, noTarget, permissionRequired, focusUnavailable, unsupportedTarget, unconfirmed, cancelled

    var succeeded: Bool { self == .inserted || self == .pasteSubmitted }

    var recoveryMessage: String {
        switch self {
        case .permissionRequired: "Enable Accessibility in System Settings to insert text into other apps."
        case .focusUnavailable: "Could not restore the dictation destination. Select the intended input, then retry insertion or copy your text."
        case .unsupportedTarget: "This app does not expose a supported text input. Copy your text into the intended field."
        case .unconfirmed: "Insertion could not be confirmed. Check your app before retrying to avoid duplicate text."
        default: "Select a text field, then retry insertion, or copy your text."
        }
    }
}

@MainActor
struct TextInsertionTarget {
    let application: NSRunningApplication
    let element: AXUIElement?
    let window: AXUIElement?
    let terminalSession: AXUIElement?
    var windowTitle: String? = nil
    var documentPath: String? = nil
    var surroundingText: String? = nil

    var localizedName: String? { application.localizedName }
}

@MainActor
enum TextInserter {
    private static let logger = Logger(subsystem: "com.useacento.acento", category: "TextInsertion")
    private static var accessibilityPromptedThisLaunch = false

    nonisolated private struct FocusSnapshot: @unchecked Sendable {
        // AX handles are immutable references; all queries here run on a worker.
        let element: AXUIElement?
        let window: AXUIElement?
        let terminalSession: AXUIElement?
        let windowTitle: String?
        let documentPath: String?
        let surroundingText: String?
    }

    static func captureAsync(application: NSRunningApplication?) async -> TextInsertionTarget? {
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = application.processIdentifier
        let terminal = application.bundleIdentifier == "com.apple.Terminal"
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.captureFocus(pid: pid, terminal: terminal)
        }.value
        guard !Task.isCancelled else { return nil }
        return TextInsertionTarget(application: application, element: snapshot.element,
                                   window: snapshot.window, terminalSession: snapshot.terminalSession,
                                   windowTitle: snapshot.windowTitle, documentPath: snapshot.documentPath,
                                   surroundingText: snapshot.surroundingText)
    }

    nonisolated private static func captureFocus(pid: pid_t, terminal: Bool) -> FocusSnapshot {
        guard AXIsProcessTrusted() else {
            return FocusSnapshot(element: nil, window: nil, terminalSession: nil,
                                 windowTitle: nil, documentPath: nil, surroundingText: nil)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let focused = focusedElement(of: app, pid: pid)
        let window = elementAttribute(kAXWindowAttribute, of: focused ?? app)
            ?? elementAttribute(kAXFocusedWindowAttribute, of: app)
        let session = terminal ? terminalSession(in: window, focused: focused) : nil
        let windowTitle = window.flatMap { attribute(kAXTitleAttribute, of: $0) as? String }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let documentPath = window.flatMap { attribute(kAXDocumentAttribute, of: $0) as? String }
            .flatMap { raw -> String? in
                if let url = URL(string: raw), url.isFileURL { return url.lastPathComponent }
                return (raw as NSString).lastPathComponent
            }
        let surroundingText = extractContextSnippet(from: session ?? focused)
        return FocusSnapshot(element: focused, window: window,
                             terminalSession: session,
                             windowTitle: windowTitle,
                             documentPath: documentPath,
                             surroundingText: surroundingText)
    }

    /// Reads a compact snippet around the cursor (or the tail of the focused editor) so AI polishing
    /// knows function names, variable identifiers, and domain terms visible where the user is dictating.
    nonisolated private static func extractContextSnippet(from element: AXUIElement?) -> String? {
        guard let element else { return nil }
        let role = attribute(kAXRoleAttribute, of: element) as? String ?? ""
        if role == "AXSecureTextField" { return nil }
        guard let value = attribute(kAXValueAttribute, of: element) as? String,
              !value.isEmpty else { return nil }
        let nsValue = value as NSString
        let maxRadius = 600
        if let rawRange = attribute(kAXSelectedTextRangeAttribute, of: element),
           CFGetTypeID(rawRange) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rawRange as! AXValue, .cfRange, &range),
               range.location >= 0, range.location <= nsValue.length {
                let start = max(0, range.location - maxRadius)
                let end = min(nsValue.length, range.location + max(0, range.length) + maxRadius)
                if end > start {
                    let slice = nsValue.substring(with: NSRange(location: start, length: end - start))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return slice.isEmpty ? nil : slice
                }
            }
        }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= maxRadius * 2 { return cleaned }
        return String(cleaned.suffix(maxRadius * 2))
    }

    static func capture(application: NSRunningApplication?) -> TextInsertionTarget? {
        guard let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let snapshot = captureFocus(pid: application.processIdentifier,
                                    terminal: application.bundleIdentifier == "com.apple.Terminal")
        return TextInsertionTarget(application: application, element: snapshot.element,
                                   window: snapshot.window, terminalSession: snapshot.terminalSession,
                                   windowTitle: snapshot.windowTitle, documentPath: snapshot.documentPath,
                                   surroundingText: snapshot.surroundingText)
    }

    static func insert(_ text: String, into target: TextInsertionTarget?,
                       onSubmitted: (() -> Void)? = nil) async -> TextInsertionResult {
        guard !Task.isCancelled else { return .cancelled }
        guard !text.isEmpty, let target, !target.application.isTerminated,
              target.application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .noTarget }
        guard AXIsProcessTrusted() else {
            if !accessibilityPromptedThisLaunch {
                accessibilityPromptedThisLaunch = true
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return .permissionRequired
        }

        let application = target.application
        let app = AXUIElementCreateApplication(application.processIdentifier)
        let needsActivation = NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier
        if needsActivation {
            application.activate()
        }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
                try Task.checkCancellation()
                guard !application.isTerminated, ProcessInfo.processInfo.systemUptime < deadline else {
                    return failure(.focusUnavailable, application: application, reason: "activation")
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try Task.checkCancellation()

            if let window = target.window,
               !same(window, elementAttribute(kAXFocusedWindowAttribute, of: app)) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
            }
            // Do not move a live cursor back to an old AX element. Custom editors
            // routinely recreate their inputs while dictation is being processed.
            if needsActivation, let element = target.terminalSession ?? target.element,
               !same(element, elementAttribute(kAXFocusedUIElementAttribute, of: app)) {
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }

            let focusDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while true {
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                    return failure(.focusUnavailable, application: application, reason: "foreground changed")
                }
                let window = elementAttribute(kAXFocusedWindowAttribute, of: app)
                let focused = focusedElement(of: app, pid: application.processIdentifier)
                let windowMatches = target.window.map { same($0, window) } ?? true
                let session = application.bundleIdentifier == "com.apple.Terminal"
                    ? terminalSession(in: window, focused: focused) : nil
                let sessionMatches = target.terminalSession.map { same($0, session) } ?? false
                if windowMatches {
                    let element = sessionMatches ? session! : focused
                    let terminal = sessionMatches && application.bundleIdentifier == "com.apple.Terminal"
                    return await insert(text, into: element, window: window, app: app, target: target,
                                        terminal: terminal, onSubmitted: onSubmitted)
                }
                guard ProcessInfo.processInfo.systemUptime < focusDeadline else {
                    return failure(.focusUnavailable, application: application, reason: "destination window not focused")
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        } catch { return .cancelled }
    }

    private static func insert(_ text: String, into element: AXUIElement?, window: AXUIElement?, app: AXUIElement,
                                target: TextInsertionTarget, terminal: Bool,
                                onSubmitted: (() -> Void)?) async -> TextInsertionResult {
        let application = target.application
        if let element, let enabled = attribute(kAXEnabledAttribute, of: element) as? Bool, !enabled {
            return failure(.unsupportedTarget, application: application, reason: "disabled input")
        }
        var selectedTextSettable = DarwinBoolean(false)
        if let element {
            AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        }
        let role = element.flatMap { attribute(kAXRoleAttribute, of: $0) as? String }
        let editable = element.flatMap { attribute("AXEditable", of: $0) as? Bool } == true
        guard TextInsertionVerification.canAttemptPaste(role: role, selectedTextSettable: selectedTextSettable.boolValue,
                                                        editable: editable, terminal: terminal, hasWindow: window != nil) else {
            return failure(element == nil ? .noTarget : .unsupportedTarget, application: application,
                           reason: "no writing destination (\(role ?? "no focused element"))")
        }
        let webEditor = element.map { isWebEditor($0) } ?? false
        // AX roles describe accessibility, not whether an app accepts typing.
        // Canvas editors, Electron terminals and TUIs can expose only a group,
        // a web area, or no focused element at all. Let their normal paste route
        // deliver text to the live cursor. If delivery cannot be verified, keep
        // the recovery UI available instead of treating missing AX data as success.
        guard !Task.isCancelled else { return .cancelled }
        guard focusMatches(element, app: app, target: target, terminal: terminal) else {
            return failure(.focusUnavailable, application: application, reason: "focus changed before insertion")
        }
        // Terminal exposes its scrollback through AX; writing AXSelectedText is
        // not a way to send input to its running shell or terminal application.
        // Web editors need the app's paste/input events to update their internal state.
        // An AX write can change visible text without updating the chat composer.
        if let element, !terminal, !webEditor, selectedTextSettable.boolValue,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return .inserted
        }

        let before = element.flatMap { attribute(kAXValueAttribute, of: $0) as? String }
        let range = terminal ? nil : element.flatMap { selectedRange(of: $0) }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .unconfirmed
        }
        guard focusMatches(element, app: app, target: target, terminal: terminal) else {
            return failure(.focusUnavailable, application: application, reason: "focus changed before paste")
        }
        guard let previousClipboard = PasteboardRestore.prepare(text) else { return .unconfirmed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        onSubmitted?()

        let result = await confirmPaste(text, element: element, app: app, target: target,
                                        terminal: terminal, before: before, range: range)
        // Verified text was already read from the pasteboard; unverified pastes get time to finish.
        // A failed paste leaves the dictation on the pasteboard for manual recovery.
        if result.succeeded || result == .cancelled {
            PasteboardRestore.restore(previousClipboard, after: result == .inserted ? 0.2 : 1.0)
        }
        return result
    }

    private static func confirmPaste(_ text: String, element: AXUIElement?, app: AXUIElement,
                                     target: TextInsertionTarget, terminal: Bool,
                                     before: String?, range: CFRange?) async -> TextInsertionResult {
        // Never send a second paste when readback is delayed or unavailable.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        do {
            repeat {
                try await Task.sleep(nanoseconds: 50_000_000)
                let liveElement = focusedElement(of: app, pid: target.application.processIdentifier) ?? element
                let after = liveElement.flatMap { attribute(kAXValueAttribute, of: $0) as? String }
                    ?? element.flatMap { attribute(kAXValueAttribute, of: $0) as? String }
                if TextInsertionVerification.confirmed(text: text, before: before, after: after,
                                                        selection: range, terminal: terminal) { return .inserted }
                let afterRange = terminal ? nil : (liveElement.flatMap { selectedRange(of: $0) } ?? element.flatMap { selectedRange(of: $0) })
                if !terminal, TextInsertionVerification.confirmedBySelectionChange(
                    beforeRange: range, afterRange: afterRange) {
                    return .inserted
                }
                // No initial value and no initial selection means readback cannot prove insertion.
                // Do not keep polling a control that provides no usable verification.
                if before == nil && range == nil { break }
            } while ProcessInfo.processInfo.systemUptime < deadline
        } catch { return .cancelled }
        // Interactive TUIs and no-echo prompts may not expose their input via AX.
        // Report delivery separately from an insertion verified by reading text.
        let focusRetained = focusMatches(element, app: app, target: target, terminal: terminal, afterPaste: true)
        if !focusRetained { logger.notice("Paste unconfirmed: focus changed after paste") }
        return TextInsertionVerification.deliveryResult(terminal: terminal, focusRetained: focusRetained)
    }

    private static func focusMatches(_ element: AXUIElement?, app: AXUIElement,
                                     target: TextInsertionTarget, terminal: Bool,
                                     afterPaste: Bool = false) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier else { return false }
        let window = elementAttribute(kAXFocusedWindowAttribute, of: app)
        if let original = target.window, window != nil, !same(original, window) { return false }
        let focused = focusedElement(of: app, pid: target.application.processIdentifier)
        let current = terminal ? terminalSession(in: window, focused: focused) : focused
        if let element {
            if same(element, current) { return true }
            // Many editors (Electron/Web/IDE) replace the focused AX node on paste while keeping the cursor
            // inside the same window and editable area. After Cmd+V was posted to the verified target,
            // treat the window as retaining focus as long as focus did not jump to a non-text control.
            if afterPaste {
                let role = current.flatMap { attribute(kAXRoleAttribute, of: $0) as? String }
                let editable = current.flatMap { attribute("AXEditable", of: $0) as? Bool } == true
                var settable = DarwinBoolean(false)
                if let current { AXUIElementIsAttributeSettable(current, kAXSelectedTextAttribute as CFString, &settable) }
                return TextInsertionVerification.canAttemptPaste(
                    role: role, selectedTextSettable: settable.boolValue, editable: editable,
                    terminal: terminal, hasWindow: (window ?? target.window) != nil)
            }
            return false
        }
        // With no AX input, the focused application/window is the destination.
        return current == nil || afterPaste
    }

    nonisolated private static func focusedElement(of app: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let focused = elementAttribute(kAXFocusedUIElementAttribute, of: app) { return focused }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard let focused = elementAttribute(kAXFocusedUIElementAttribute, of: system) else { return nil }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == pid else { return nil }
        return focused
    }

    private static func isWebEditor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<20 {
            guard let node = current else { break }
            if attribute(kAXRoleAttribute, of: node) as? String == "AXWebArea" { return true }
            current = elementAttribute(kAXParentAttribute, of: node)
        }
        return false
    }

    nonisolated private static func terminalSession(in window: AXUIElement?, focused: AXUIElement?) -> AXUIElement? {
        if let focused {
            let role = attribute(kAXRoleAttribute, of: focused) as? String
            if role == kAXTextFieldRole || role == kAXComboBoxRole { return nil }
            if role == kAXTextAreaRole { return focused }
            // A toolbar button is not a terminal input, even if a session exists.
            guard [kAXWindowRole, kAXScrollAreaRole, kAXGroupRole, "AXUnknown"].contains(role ?? "AXUnknown") else { return nil }
        }
        guard let window else { return nil }
        var pending = [window]
        var sessions: [AXUIElement] = []
        var inspected = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while !pending.isEmpty && inspected < 100 && ProcessInfo.processInfo.systemUptime < deadline {
            let element = pending.removeFirst()
            inspected += 1
            if attribute(kAXRoleAttribute, of: element) as? String == kAXTextAreaRole {
                if attribute(kAXFocusedAttribute, of: element) as? Bool == true { return element }
                sessions.append(element)
            } else if let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(100 - inspected))
            }
        }
        return sessions.count == 1 ? sessions.first : nil
    }

    private static func failure(_ result: TextInsertionResult, application: NSRunningApplication, reason: String) -> TextInsertionResult {
        logger.notice("Insertion stopped: \(application.bundleIdentifier ?? "unknown", privacy: .public), \(reason, privacy: .public)")
        return result
    }

    private static func same(_ first: AXUIElement, _ second: AXUIElement?) -> Bool {
        second.map { CFEqual(first, $0) } ?? false
    }

    nonisolated private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}
