import AppKit
import LocalFlowCore

protocol HotkeyDelegate: AnyObject {
    func pushToTalkPressed()
    func pushToTalkReleased()
    /// Another key was pressed while the push-to-talk key was held (e.g. Fn+←).
    func pushToTalkInterrupted()
    func handsFreeToggled()
    func cancelPressed() -> Bool
    func pasteLastPressed()
    func copyLastPressed()
}

/// Global shortcuts through a session event tap. Requires Accessibility
/// permission; only shortcut keys are consumed, everything else passes through.
final class HotkeyMonitor {
    weak var delegate: HotkeyDelegate?
    var shortcuts: Shortcuts

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pttHeld = false

    init(shortcuts: Shortcuts) { self.shortcuts = shortcuts }

    /// Returns false when Accessibility permission has not been granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ref in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(ref!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            }, userInfo: ref)
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func pttKeyCodes() -> (codes: Set<Int64>, flag: CGEventFlags) {
        switch shortcuts.pushToTalk {
        case .fn: ([63, 179], .maskSecondaryFn)
        case .rightOption: ([61], .maskAlternate)
        case .rightCommand: ([54], .maskCommand)
        case .rightControl: ([62], .maskControl)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if type == .flagsChanged {
            let (codes, flag) = pttKeyCodes()
            if codes.contains(keyCode) {
                let down = flags.contains(flag)
                if down && !pttHeld {
                    pttHeld = true
                    delegate?.pushToTalkPressed()
                } else if !down && pttHeld {
                    pttHeld = false
                    delegate?.pushToTalkReleased()
                }
            } else if pttHeld {
                // A different modifier joined the PTT key: likely a system shortcut.
                delegate?.pushToTalkInterrupted()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let hf = shortcuts.handsFree
        if hf.withPushToTalkKey {
            if pttHeld && keyCode == Int64(hf.keyCode) {
                if !isRepeat { delegate?.handsFreeToggled() }
                return nil
            }
        } else if matches(hf, keyCode: keyCode, flags: flags) {
            if !isRepeat { delegate?.handsFreeToggled() }
            return nil
        }

        if pttHeld {
            delegate?.pushToTalkInterrupted()
            return Unmanaged.passUnretained(event)
        }
        if matches(shortcuts.cancel, keyCode: keyCode, flags: flags), delegate?.cancelPressed() == true {
            return nil
        }
        if matches(shortcuts.pasteLast, keyCode: keyCode, flags: flags) {
            if !isRepeat { delegate?.pasteLastPressed() }
            return nil
        }
        if matches(shortcuts.copyLast, keyCode: keyCode, flags: flags) {
            if !isRepeat { delegate?.copyLastPressed() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func matches(_ chord: KeyChord, keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == Int64(chord.keyCode)
            && flags.contains(.maskCommand) == chord.command
            && flags.contains(.maskControl) == chord.control
            && flags.contains(.maskAlternate) == chord.option
            && flags.contains(.maskShift) == chord.shift
    }
}
