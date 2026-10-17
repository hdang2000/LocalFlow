import AppKit
import Carbon.HIToolbox

enum InsertOutcome {
    case pasted
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
        guard focusedElementAcceptsText() else {
            copy(text)
            return .copiedNoTarget
        }

        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        postCommandV()
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

    /// Asks Accessibility for the focused element's role only; its contents
    /// are never read. Unknown roles are treated as editable, since many apps
    /// (browsers, Electron editors) expose custom roles.
    static func focusedElementAcceptsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            // Some apps don't expose focus at all; paste anyway and let them decide.
            return focusQueryUnsupported()
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let nonText: Set<String> = [kAXButtonRole, kAXImageRole, kAXMenuItemRole, kAXCheckBoxRole,
                                    kAXRadioButtonRole, kAXSliderRole, kAXListRole, kAXOutlineRole]
        if let r = role as? String, nonText.contains(r) {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element as! AXUIElement, kAXValueAttribute as CFString, &settable)
            return settable.boolValue
        }
        return true
    }

    /// When nothing reports focus, the desktop/Finder is usually frontmost.
    private static func focusQueryUnsupported() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front != "com.apple.finder" && front != nil
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
