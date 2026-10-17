import AppKit
import Carbon.HIToolbox

enum InsertOutcome {
    case pasted
    /// Pasted, but the target couldn't be confirmed, so the transcript was
    /// left on the clipboard instead of restoring the previous contents.
    case pastedKeptOnClipboard
    /// No editable text field had focus, or secure input blocked pasting; the
    /// text is on the clipboard instead.
    case copiedNoTarget
    case copiedSecureInput
}

/// Inserts text into the focused app by pasting, then restores the clipboard.
/// It only ever sends ⌘V: never Return, so dictated commands are not executed.
enum TextInserter {
    static func insert(_ text: String) async -> InsertOutcome {
        if IsSecureEventInputEnabled() {
            copy(text)
            return .copiedSecureInput
        }
        let target = focusedTarget()
        guard target != .none else {
            copy(text)
            return .copiedNoTarget
        }

        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        postCommandV()
        // Restore the previous clipboard only when a text field certainly took
        // the paste. Otherwise the paste may have gone nowhere, so the
        // transcript stays on the clipboard for the user's own ⌘V.
        guard target == .textField else { return .pastedKeptOnClipboard }
        // Give the target app time to read the clipboard before restoring it.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if pb.changeCount == ourChange { restore(saved, to: pb) }
        return .pasted
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func paste(_ text: String) async -> InsertOutcome { await insert(text) }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    enum Target { case textField, unknown, none }

    /// Asks Accessibility for the focused element's role only; its contents
    /// are never read.
    /// - textField: a known editable role, or an element whose value is settable.
    /// - none: nothing focused that could take text (Finder/desktop, buttons…).
    /// - unknown: the app doesn't say (common in Electron and web apps).
    static func focusedTarget() -> Target {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            return front == nil || front == "com.apple.finder" ? .none : .unknown
        }
        let element = ref as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        if textRoles.contains(role) { return .textField }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settable.boolValue { return .textField }
        let nonText: Set<String> = [kAXButtonRole, kAXImageRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole,
                                    kAXSliderRole, kAXListRole, kAXOutlineRole, kAXTableRole, kAXWindowRole,
                                    kAXScrollAreaRole, kAXToolbarRole, kAXMenuBarRole]
        if nonText.contains(role) { return .none }
        return .unknown
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { dict in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        })
    }
}
