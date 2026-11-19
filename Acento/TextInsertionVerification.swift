import Foundation

nonisolated enum TextInsertionVerification {
    static func deliveryResult(terminal: Bool, focusRetained: Bool) -> TextInsertionResult {
        // Terminals, TUIs and web/Electron editors often don't expose readable text.
        // If the paste went to the same app, window and input that was focused
        // before sending it, treat it as delivered; recovery is only for lost focus.
        terminal || focusRetained ? .pasteSubmitted : .unconfirmed
    }

    static func canAttemptPaste(role: String?, selectedTextSettable: Bool, editable: Bool,
                                terminal: Bool, hasWindow: Bool) -> Bool {
        if terminal || selectedTextSettable || editable { return true }
        if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") { return true }
        guard hasWindow else { return false }
        // Preserve the single-paste fallback for custom/canvas editors, but do
        // not paste into explicit navigation, selection, or action controls.
        let nonTextRoles = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXLink",
                            "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXPopUpButton",
                            "AXToolbar", "AXTabGroup", "AXTab", "AXSlider", "AXScrollBar",
                            "AXStaticText", "AXImage", "AXIcon", "AXOutline", "AXTable",
                            "AXList", "AXRow", "AXCell", "AXBrowser", "AXApplication"]
        return !nonTextRoles.contains(role ?? "")
    }

    static func confirmed(text: String, before: String?, after: String?, selection: CFRange?, terminal: Bool) -> Bool {
        guard !text.isEmpty, let before, let after, before != after else { return false }
        if !terminal, let selection,
           selection.location >= 0, selection.length >= 0,
           selection.location <= (before as NSString).length,
           selection.length <= (before as NSString).length - selection.location {
            let expected = (before as NSString).replacingCharacters(
                in: NSRange(location: selection.location, length: selection.length), with: text)
            if after == expected { return true }
        }
        func normalized(_ value: String) -> String {
            terminal ? value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") : value
        }
        let needle = normalized(text)
        guard !needle.isEmpty else { return false }
        // A transcript already present in scrollback is not proof of a new paste.
        if normalized(after).components(separatedBy: needle).count
            > normalized(before).components(separatedBy: needle).count {
            return true
        }
        // Rich editors and IDEs often convert regular spaces to non-breaking spaces, smart quotes,
        // or auto-indent pasted lines; compare with collapsed whitespace as well.
        func collapsed(_ value: String) -> String {
            value.replacingOccurrences(of: "\u{00A0}", with: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let collapsedNeedle = collapsed(text)
        guard !collapsedNeedle.isEmpty else { return false }
        return collapsed(after).components(separatedBy: collapsedNeedle).count
            > collapsed(before).components(separatedBy: collapsedNeedle).count
    }

    /// Confirms insertion when an editor does not expose updated AXValue text
    /// but advances the cursor selection after Cmd+V inside the same editable field.
    static func confirmedBySelectionChange(beforeRange: CFRange?, afterRange: CFRange?) -> Bool {
        guard let beforeRange, let afterRange, beforeRange.location >= 0, afterRange.location >= 0 else { return false }
        if afterRange.location > beforeRange.location { return true }
        if beforeRange.length > 0 && afterRange.length == 0 && afterRange.location >= beforeRange.location { return true }
        return false
    }
}
