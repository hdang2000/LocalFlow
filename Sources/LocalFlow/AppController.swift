import AppKit
import LocalFlowCore

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalFlow", isDirectory: true)
    }()
    static let settings = support.appendingPathComponent("settings.json")
    static let history = support.appendingPathComponent("history.json")
    static let failedAudio = support.appendingPathComponent("last-failed.wav")
}

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var raw: String
    var text: String
    var app: String?
}

/// The dictation state machine shared by the hotkeys, indicator and menu.
final class AppController: HotkeyDelegate {
    enum State: Equatable { case idle, recording(handsFree: Bool), processing }

    private(set) var settings: Settings
    private(set) var history: [HistoryItem] = []
    static let didChange = Notification.Name("LocalFlowControllerDidChange")
    private(set) var state: State = .idle {
        didSet {
            // The idle clock runs only between dictations.
            if state == .idle { scheduleIdleUnload() } else { idleUnloadTimer?.invalidate() }
            changed()
        }
    }
    var onChange: (() -> Void)?

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    let indicator = IndicatorPanel()
    let hotkeys: HotkeyMonitor
    private let recorder = AudioRecorder()
    let whisper = WhisperServer()
    private let settingsStore = JSONStore<Settings>(url: Paths.settings)
    private let historyStore = JSONStore<[HistoryItem]>(url: Paths.history)

    private var recordStart = Date()
    private var pttPressedAt = Date()
    private var limitTimer: Timer?
    private var idleUnloadTimer: Timer?
    /// True when the model was unloaded for being idle (not still loading).
    var engineSleeping: Bool { !whisper.isRunning && !whisper.isStarting }
    /// The frontmost app when recording began; read only if the user allowed it.
    private var targetBundleID: String?
    private var failedAudio: Data?

    var lastTranscript: String? { history.first?.text }
    var hasFailedAudio: Bool { failedAudio != nil }

    /// False for the in-memory demo used to render README screenshots.
    private let persist: Bool
    var isDemo: Bool { !persist }

    init() {
        persist = true
        settings = (try? settingsStore.load()) ?? Settings()
        hotkeys = HotkeyMonitor(shortcuts: settings.shortcuts)
        if settings.keepHistory { history = (try? historyStore.load()) ?? [] }
        failedAudio = try? Data(contentsOf: Paths.failedAudio)
        wire()
    }

    /// An in-memory controller with sample data; never reads or writes the
    /// user's settings or history.
    init(demoSettings: Settings, demoHistory: [HistoryItem]) {
        persist = false
        settings = demoSettings
        history = demoHistory
        hotkeys = HotkeyMonitor(shortcuts: demoSettings.shortcuts)
        wire()
    }

    private func wire() {
        hotkeys.delegate = self
        recorder.onLevel = { [weak self] in self?.indicator.model.push(level: $0) }
        indicator.onCancel = { [weak self] in self?.cancel() }
        indicator.onFinish = { [weak self] in self?.finish() }
        indicator.onRetry = { [weak self] in self?.retryFailed() }
        indicator.onDismiss = { [weak self] in self?.indicator.show(.hidden) }
        indicator.onStart = { [weak self] in self?.startRecording(handsFree: true) }
        indicator.idleBarEnabled = settings.showIdleBar
    }

    func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        if persist { try? settingsStore.save(settings) }
        hotkeys.shortcuts = settings.shortcuts
        if state == .idle { scheduleIdleUnload() }
        indicator.idleBarEnabled = settings.showIdleBar
        if !settings.keepHistory {
            history.removeAll()
            if persist { try? FileManager.default.removeItem(at: Paths.history) }
        }
        changed()
    }

    /// Loads the model in the background so the first dictation is fast.
    func warmUp() {
        Task { @MainActor in
            do {
                try await whisper.ensureStarted()
                scheduleIdleUnload()
                changed()
            } catch {
                showError(error.localizedDescription, canRetry: false)
            }
        }
    }

    /// Frees the model's memory after `idleUnloadMinutes` without dictation.
    private func scheduleIdleUnload() {
        idleUnloadTimer?.invalidate()
        let minutes = settings.idleUnloadMinutes
        guard minutes > 0 else { return }
        idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            guard let self, self.state == .idle, self.whisper.isRunning else { return }
            self.whisper.stop()
            self.changed()
        }
    }

    // MARK: HotkeyDelegate

    func pushToTalkPressed() {
        pttPressedAt = Date()
        switch state {
        case .idle: startRecording(handsFree: false)
        case .recording(handsFree: true): finish() // tapping PTT ends hands-free mode
        default: break
        }
    }

    func pushToTalkReleased() {
        guard state == .recording(handsFree: false) else { return }
        if Date().timeIntervalSince(pttPressedAt) < 0.35 {
            discardRecording()
            indicator.show(.notice("Hold the push-to-talk key while you speak", isError: false, canRetry: false),
                           autoHideAfter: 2)
            return
        }
        finish()
    }

    func pushToTalkInterrupted() {
        // Fn+arrow and similar shortcuts shouldn't start a dictation.
        if state == .recording(handsFree: false), Date().timeIntervalSince(pttPressedAt) < 1.0 {
            discardRecording()
            indicator.show(.hidden)
        }
    }

    func handsFreeToggled() {
        switch state {
        case .idle: startRecording(handsFree: true)
        case .recording(handsFree: false): state = .recording(handsFree: true); indicator.show(.listening(handsFree: true))
        case .recording(handsFree: true): finish()
        case .processing: break
        }
    }

    func cancelPressed() -> Bool {
        guard case .recording = state else { return false }
        cancel()
        return true
    }

    func pasteLastPressed() {
        guard let text = lastTranscript else { return }
        Task { @MainActor in report(await TextInserter.paste(text), text: text) }
    }

    func copyLastPressed() {
        guard let text = lastTranscript else { return }
        TextInserter.copy(text)
        indicator.show(.notice("Copied last transcript", isError: false, canRetry: false), autoHideAfter: 1.5)
    }

    // MARK: Recording

    func startRecording(handsFree: Bool) {
        guard state == .idle else { return }
        // Start (re)loading the model now, so it loads while you speak.
        idleUnloadTimer?.invalidate()
        Task { @MainActor in
            try? await whisper.ensureStarted()
            changed()
        }
        Task { @MainActor in
            guard await AudioRecorder.requestPermission() else {
                showError("Microphone access is off. Enable LocalFlow in System Settings → Privacy & Security → Microphone.", canRetry: false)
                return
            }
            do {
                targetBundleID = settings.useActiveAppForStyle
                    ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
                try recorder.start()
                recordStart = Date()
                state = .recording(handsFree: handsFree)
                indicator.show(.listening(handsFree: handsFree))
                if settings.playSounds { NSSound(named: "Tink")?.play() }
                startLimitTimer()
            } catch {
                showError(error.localizedDescription, canRetry: false)
            }
        }
    }

    private func startLimitTimer() {
        limitTimer?.invalidate()
        let limit = settings.maxRecordingSeconds
        limitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, case .recording = self.state else { return }
            let elapsed = Date().timeIntervalSince(self.recordStart)
            self.indicator.model.limitWarning = elapsed > limit - 60
            if elapsed >= limit { self.finish() }
        }
    }

    func cancel() {
        guard case .recording = state else { return }
        discardRecording()
        indicator.show(.notice("Cancelled", isError: false, canRetry: false), autoHideAfter: 1)
    }

    private func discardRecording() {
        limitTimer?.invalidate()
        _ = recorder.stop()
        state = .idle
    }

    func finish() {
        guard case .recording = state else { return }
        limitTimer?.invalidate()
        let samples = recorder.stop()
        if settings.playSounds { NSSound(named: "Pop")?.play() }
        guard samples.count > Int(AudioRecorder.sampleRate * 0.3), AudioRecorder.peak(samples) > 0.01 else {
            state = .idle
            showError("We couldn't hear you. Is your microphone muted?", canRetry: false)
            return
        }
        transcribe(wav: AudioRecorder.wav(from: samples))
    }

    func retryFailed() {
        guard state == .idle, let wav = failedAudio else { return }
        transcribe(wav: wav)
    }

    private func transcribe(wav: Data) {
        state = .processing
        indicator.show(.processing)
        let options = PipelineOptions(settings: settings, bundleID: targetBundleID)
        let prompt = TextPipeline.recognitionPrompt(options: options)
        let language = settings.language
        Task { @MainActor in
            do {
                let raw = try await whisper.transcribe(wav: wav, language: language, prompt: prompt)
                let text = TextPipeline.process(raw, options: options)
                clearFailedAudio()
                state = .idle
                guard !text.isEmpty else {
                    showError("No speech detected", canRetry: false)
                    return
                }
                record(raw: raw, text: text)
                report(await TextInserter.insert(text), text: text)
            } catch {
                // Keep the audio so the user can retry without speaking again.
                failedAudio = wav
                try? wav.write(to: Paths.failedAudio, options: .atomic)
                state = .idle
                showError(error.localizedDescription, canRetry: true)
            }
        }
    }

    @MainActor private func report(_ outcome: InsertOutcome, text: String) {
        switch outcome {
        case .pasted:
            indicator.show(.hidden)
        case .copiedNoTarget:
            indicator.show(.notice("No text field focused — copied. Click a text box and press ⌘V.", isError: false, canRetry: false),
                           autoHideAfter: 4)
        case .copiedSecureInput:
            indicator.show(.notice("Secure input is on (password field?) — copied to clipboard instead.", isError: false, canRetry: false),
                           autoHideAfter: 4)
        }
    }

    private func showError(_ message: String, canRetry: Bool) {
        indicator.show(.notice(message, isError: true, canRetry: canRetry), autoHideAfter: canRetry ? nil : 4)
    }

    private func clearFailedAudio() {
        failedAudio = nil
        try? FileManager.default.removeItem(at: Paths.failedAudio)
    }

    private func record(raw: String, text: String) {
        history.insert(HistoryItem(date: Date(), raw: raw, text: text, app: targetBundleID), at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        if persist && settings.keepHistory { try? historyStore.save(history) }
        changed()
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        if persist && settings.keepHistory { try? historyStore.save(history) }
        changed()
    }

    func clearHistory() {
        history.removeAll()
        if persist { try? FileManager.default.removeItem(at: Paths.history) }
        changed()
    }
}
