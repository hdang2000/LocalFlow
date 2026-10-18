import AppKit
import ApplicationServices
import Carbon
import LocalFlowCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = AppController()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var model: AppViewModel?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        handleTermination()
        DebugLog.write("launched")
        watchSecureInput()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.refreshIcon(); self?.applyDockPolicy() }
        refreshIcon()
        applyDockPolicy()
        controller.indicator.show(.hidden) // shows the idle bar if enabled
        if controller.settings.showDockIcon { showMainWindow() }

        startHotkeysWhenTrusted()
        controller.warmUp()
        Task { _ = await AudioRecorder.requestPermission() }
    }

    func applicationWillTerminate(_ note: Notification) {
        controller.whisper.stop()
    }

    /// `kill`/logout send SIGTERM, which skips applicationWillTerminate;
    /// stop the speech engine child before exiting.
    private var termSource: DispatchSourceSignal?
    func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            self?.controller.whisper.stop()
            exit(0)
        }
        src.resume()
        termSource = src
    }

    /// Accessibility is needed for global shortcuts and pasting. Prompt once,
    /// then keep checking until it is granted.
    private func startHotkeysWhenTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), controller.hotkeys.start() { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted(), self.controller.hotkeys.start() else { return }
            t.invalidate()
            self.refreshIcon()
        }
    }

    private var secureInputTimer: Timer?
    private var secureInputOn = false

    /// Secure Input hides every key press from LocalFlow; show it on the icon.
    private func watchSecureInput() {
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let on = IsSecureEventInputEnabled()
            if on != self.secureInputOn {
                self.secureInputOn = on
                DebugLog.write("secure input \(on ? "ON - shortcuts unavailable" : "off")")
                self.refreshIcon()
            }
        }
    }

    private func refreshIcon() {
        if secureInputOn && controller.state == .idle {
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "LocalFlow — shortcuts paused")
            return
        }
        let name: String
        switch controller.state {
        case .idle: name = "waveform"
        case .recording: name = "waveform.circle.fill"
        case .processing: name = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "LocalFlow")
    }

    // Rebuild the menu each time it opens so it reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = controller.settings
        let ptt = s.shortcuts.pushToTalk.displayName
        menu.addItem(disabled("Hold \(ptt) to dictate · \(s.shortcuts.handsFree.displayName.replacingOccurrences(of: "PTT", with: ptt)) hands-free"))
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Grant Accessibility permission…", #selector(openAccessibility)))
        }
        if IsSecureEventInputEnabled() {
            menu.addItem(disabled("⚠︎ Shortcuts paused: another app has Secure Input on"))
            menu.addItem(disabled("    (a password field, or Terminal → Secure Keyboard Entry)"))
        }
        let engine = controller.whisper.isRunning ? "ready (offline)"
            : controller.engineSleeping ? "sleeping — loads when you dictate" : "loading…"
        menu.addItem(disabled("Speech engine: " + engine))
        menu.addItem(.separator())

        switch controller.state {
        case .idle: menu.addItem(item("Start Hands-free Dictation", #selector(startHandsFree)))
        case .recording: menu.addItem(item("Finish Dictation", #selector(finish)))
        case .processing: menu.addItem(disabled("Transcribing…"))
        }
        menu.addItem(item("Open LocalFlow", #selector(openMain)))
        let paste = item("Paste Last Transcript", #selector(pasteLast))
        paste.isEnabled = controller.lastTranscript != nil
        menu.addItem(paste)
        let copy = item("Copy Last Transcript", #selector(copyLast))
        copy.isEnabled = controller.lastTranscript != nil
        menu.addItem(copy)
        if controller.hasFailedAudio {
            menu.addItem(item("Retry Failed Transcription", #selector(retry)))
        }

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for h in controller.history.prefix(10) {
            let i = item(String(h.text.replacingOccurrences(of: "\n", with: " ").prefix(60)), #selector(copyHistory(_:)))
            i.representedObject = h.text
            i.toolTip = "Click to copy"
            sub.addItem(i)
        }
        if controller.history.isEmpty { sub.addItem(disabled("No transcripts yet")) }
        else { sub.addItem(.separator()); sub.addItem(item("Clear History", #selector(clearHistory))) }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())

        let style = NSMenuItem(title: "Default Style", action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for st in WritingStyle.allCases {
            let i = item(st.displayName, #selector(pickStyle(_:)))
            i.representedObject = st.rawValue
            i.state = s.defaultStyle == st ? .on : .off
            styles.addItem(i)
        }
        style.submenu = styles
        menu.addItem(style)
        let dev = item("Developer Mode", #selector(toggleDev))
        dev.state = s.developerMode ? .on : .off
        menu.addItem(dev)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit LocalFlow", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func openMain() { showMainWindow() }
    @objc private func startHandsFree() { controller.startRecording(handsFree: true) }
    @objc private func finish() { controller.finish() }
    @objc private func retry() { controller.retryFailed() }
    @objc private func copyLast() { controller.copyLastPressed() }
    @objc private func clearHistory() { controller.clearHistory() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleDev() { controller.update { $0.developerMode.toggle() } }

    @objc private func pasteLast() {
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.controller.pasteLastPressed() }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { TextInserter.copy(text) }
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = WritingStyle(rawValue: raw) else { return }
        controller.update { $0.defaultStyle = st }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() { showMainWindow(page: .settings) }

    func showMainWindow(page: Page? = nil) {
        if mainWindow == nil {
            model = AppViewModel(controller: controller)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "LocalFlow"
            w.contentView = NSHostingView(rootView: MainView(store: model!))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("LocalFlowMain")
            if !w.setFrameUsingName("LocalFlowMain") { w.center() }
            mainWindow = w
        }
        if let page { model?.section = page }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Clicking the Dock icon reopens the window, like a regular app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Closing the window keeps dictation running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = controller.settings.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .accessory { mainWindow?.makeKeyAndOrderFront(nil) }
        }
    }
}

// Headless mode for testing the real engine and pipeline on an audio file:
//   LocalFlow --transcribe file.wav [--dev] [--style casual] [--language hinglish] [--settings file.json]
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    let args = CommandLine.arguments
    let settingsURL = args.firstIndex(of: "--settings").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    var settings = (try? JSONStore<LocalFlowCore.Settings>(url: settingsURL ?? Paths.settings).load()) ?? LocalFlowCore.Settings()
    if args.contains("--dev") { settings.developerMode = true }
    if let l = args.firstIndex(of: "--language"), l + 1 < args.count { settings.language = args[l + 1] }
    if let s = args.firstIndex(of: "--style"), s + 1 < args.count, let st = WritingStyle(rawValue: args[s + 1]) {
        settings.defaultStyle = st
    }
    let options = PipelineOptions(settings: settings, bundleID: nil)
    let server = WhisperServer()
    let sem = DispatchSemaphore(value: 0)
    Task {
        defer { server.stop(); sem.signal() }
        do {
            let wav = try Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
            let start = Date()
            try await server.ensureStarted()
            let loaded = Date()
            let raw = try await server.transcribe(wav: wav, language: settings.language,
                                                  prompt: TextPipeline.recognitionPrompt(options: options))
            let done = Date()
            print("RAW:   " + raw.trimmingCharacters(in: .whitespacesAndNewlines))
            print("FINAL: " + TextPipeline.process(raw, options: options))
            print(String(format: "TIMING: model load %.2fs, transcription %.2fs", loaded.timeIntervalSince(start), done.timeIntervalSince(loaded)))
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }
    sem.wait()
    exit(0)
}

// Renders README screenshots from the real views with sample data:
//   LocalFlow --render-screenshots docs/screenshots
if let i = CommandLine.arguments.firstIndex(of: "--render-screenshots"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    do { try Screenshots.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
