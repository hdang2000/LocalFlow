import AppKit
import LocalFlowCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, dictionary, snippets, styles, tryIt, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .styles: "Styles"
        case .tryIt: "Try It"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .styles: "textformat"
        case .tryIt: "wand.and.stars"
        case .settings: "gearshape"
        }
    }
}

/// Bridges the controller to SwiftUI: saves every settings change and
/// refreshes when dictation state or history changes.
final class AppViewModel: ObservableObject {
    let controller: AppController
    @Published var settings: LocalFlowCore.Settings {
        didSet { if settings != oldValue { controller.update { $0 = settings } } }
    }
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var state: AppController.State = .idle
    @Published private(set) var engineReady = false
    @Published private(set) var engineSleeping = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published var section: Page? = .home
    @Published var historySearch = ""

    // Draft fields for the add forms (kept here: no @State without Xcode's macros).
    @Published var draftTerm = ""
    @Published var draftCorrections = ""
    @Published var draftTrigger = ""
    @Published var draftExpansion = ""
    @Published var tryInput = "um so send it to John, no wait, to Sarah new paragraph my list is one milk two eggs three bread"

    private var observer: NSObjectProtocol?
    private var poll: Timer?

    init(controller: AppController) {
        self.controller = controller
        settings = controller.settings
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AppController.didChange, object: controller, queue: .main) { [weak self] _ in self?.refresh() }
        // Engine and permission status change outside the controller's events.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        poll?.invalidate()
    }

    func refresh() {
        history = controller.history
        state = controller.state
        if controller.isDemo {
            // Screenshots show the normal, fully set-up state.
            engineReady = true
            engineSleeping = false
            accessibilityGranted = true
            return
        }
        if engineReady != controller.whisper.isRunning { engineReady = controller.whisper.isRunning }
        if engineSleeping != controller.engineSleeping { engineSleeping = controller.engineSleeping }
        if accessibilityGranted != AXIsProcessTrusted() { accessibilityGranted = AXIsProcessTrusted() }
    }

    func preview(_ text: String) -> String {
        TextPipeline.process(text, options: PipelineOptions(settings: settings, bundleID: nil))
    }

    var filteredHistory: [HistoryItem] {
        let q = historySearch.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? history : history.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var pttName: String { settings.shortcuts.pushToTalk.displayName }
    var handsFreeName: String {
        settings.shortcuts.handsFree.displayName.replacingOccurrences(of: "PTT", with: pttName)
    }
}

struct MainView: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $store.section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle((store.section ?? .home).title)
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    @ViewBuilder private var detail: some View {
        switch store.section ?? .home {
        case .home: HomePage(store: store)
        case .history: HistoryPage(store: store)
        case .dictionary: DictionaryTab(store: store).padding()
        case .snippets: SnippetsTab(store: store).padding()
        case .styles: StylesTab(store: store)
        case .tryIt: TryItTab(store: store).padding()
        case .settings: GeneralTab(store: store)
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 6) {
            Circle().fill(store.engineReady ? Color.green : (store.engineSleeping ? Color.gray : Color.orange))
                .frame(width: 7, height: 7)
            Text(store.engineReady ? "Offline engine ready" : (store.engineSleeping ? "Engine sleeping (frees memory)" : "Loading engine…"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
    }
}

private struct HomePage: View {
    @ObservedObject var store: AppViewModel

    private var words: Int { store.history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
    private var today: Int { store.history.filter { Calendar.current.isDateInToday($0.date) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if !store.accessibilityGranted { permissionCard }
                HStack(spacing: 12) {
                    StatCard(value: "\(words)", label: "Words dictated")
                    StatCard(value: "\(store.history.count)", label: "Transcripts")
                    StatCard(value: "\(today)", label: "Today")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent").font(.headline)
                        Spacer()
                        if !store.history.isEmpty { Button("See all") { store.section = .history } }
                    }
                    if store.history.isEmpty {
                        Text("Your transcripts will appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(store.history.prefix(5)) { HistoryRow(item: $0, store: store) }
                }
            }
            .padding(24)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusTitle).font(.title2.bold())
            HStack(spacing: 16) {
                ShortcutHint(keys: store.pttName, label: "Hold to dictate")
                ShortcutHint(keys: store.handsFreeName, label: "Hands-free")
                ShortcutHint(keys: "Esc", label: "Cancel")
                ShortcutHint(keys: "⌃⌘V", label: "Paste last")
            }
            HStack {
                Button {
                    store.controller.startRecording(handsFree: true)
                } label: { Label("Start Hands-free Dictation", systemImage: "mic.fill") }
                .controlSize(.large)
                .disabled(store.state != .idle)
                Text(store.settings.developerMode ? "Developer mode on" : "Style: \(store.settings.defaultStyle.displayName.components(separatedBy: " —").first ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08)))
    }

    private var statusTitle: String {
        switch store.state {
        case .idle: "Ready when you are"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    private var permissionCard: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text("Accessibility permission needed").bold()
                Text("LocalFlow needs it for global shortcuts and to paste into other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

private struct ShortcutHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(keys).font(.caption.monospaced().bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var store: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).textSelection(.enabled).lineLimit(4)
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { TextInserter.copy(item.text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
            Button { store.controller.deleteHistory(item.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

private struct HistoryPage: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search transcripts", text: $store.historySearch).textFieldStyle(.roundedBorder)
                Button("Clear All", role: .destructive) { store.controller.clearHistory() }
                    .disabled(store.history.isEmpty)
            }
            if !store.settings.keepHistory {
                Text("History is off. Turn it on in Settings → Privacy.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.filteredHistory) { HistoryRow(item: $0, store: store) }
                }
            }
        }
        .padding()
    }
}

struct GeneralTab: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        Form {
            Section("Shortcuts") {
                Picker("Push to talk (hold)", selection: $store.settings.shortcuts.pushToTalk) {
                    ForEach(PushToTalkKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Hands-free (press to start/stop)", selection: $store.settings.shortcuts.handsFree) {
                    ForEach(Shortcuts.handsFreePresets, id: \.self) { chord in
                        Text(chord.displayName.replacingOccurrences(of: "PTT", with: store.settings.shortcuts.pushToTalk.displayName)).tag(chord)
                    }
                }
                LabeledContent("Cancel recording", value: store.settings.shortcuts.cancel.displayName)
                LabeledContent("Paste last transcript", value: store.settings.shortcuts.pasteLast.displayName)
                LabeledContent("Copy last transcript", value: store.settings.shortcuts.copyLast.displayName)
                if store.settings.shortcuts.pushToTalk == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so Fn doesn't open the emoji picker or Apple dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Dictation") {
                Picker("Language", selection: $store.settings.language) {
                    Text("Hinglish + English (Roman letters)").tag("hinglish")
                    Text("English only").tag("en")
                    Text("Auto-detect (native script)").tag("auto")
                    Text("Hindi (Devanagari)").tag("hi")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                }
                Toggle("Remove filler words (um, uh, you know)", isOn: $store.settings.removeFillers)
                Toggle("Backtracking (“2pm, actually 3pm” → “3pm”)", isOn: $store.settings.backtracking)
                Toggle("Spoken punctuation (“comma”, “new line”)", isOn: $store.settings.spokenPunctuation)
                Toggle("Format spoken lists", isOn: $store.settings.autoLists)
                Toggle("Developer mode everywhere", isOn: $store.settings.developerMode)
                Toggle("Play sounds", isOn: $store.settings.playSounds)
                Picker("Free memory when idle", selection: $store.settings.idleUnloadMinutes) {
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                    Text("Never (always ready)").tag(0)
                }
                Text("Unloads the speech model (~1.9 GB) when you haven't dictated for a while. It reloads as soon as you press the shortcut, usually while you're still speaking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Show in Dock", isOn: $store.settings.showDockIcon)
                Toggle("Show idle bar at the bottom of the screen", isOn: $store.settings.showIdleBar)
            }
            Section("Privacy") {
                Toggle("Keep transcript history on this Mac", isOn: $store.settings.keepHistory)
                Text("All speech recognition runs locally with whisper.cpp. Nothing is sent over the network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DictionaryTab: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Names, brands, acronyms and technical terms. Terms also guide the speech model; corrections rewrite common misrecognitions.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Term (e.g. a name or brand)", text: $store.draftTerm)
                TextField("Misheard as (comma-separated, optional)", text: $store.draftCorrections)
                Button("Add") {
                    let t = store.draftTerm.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    let c = store.draftCorrections.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.settings.dictionary.append(DictionaryEntry(term: t, corrections: c))
                    store.draftTerm = ""; store.draftCorrections = ""
                }
            }
            List {
                ForEach(store.settings.dictionary) { e in
                    HStack {
                        Text(e.term).bold()
                        if !e.corrections.isEmpty {
                            Text("← " + e.corrections.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.settings.dictionary.removeAll { $0.id == e.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

struct SnippetsTab: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Say the trigger phrase and it is replaced with the text below, exactly as written.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Trigger phrase (e.g. my calendar link)", text: $store.draftTrigger)
            TextEditor(text: $store.draftExpansion).frame(height: 70).border(Color.secondary.opacity(0.3))
            Button("Add Snippet") {
                let t = store.draftTrigger.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !store.draftExpansion.isEmpty else { return }
                store.settings.snippets.append(Snippet(trigger: t, expansion: store.draftExpansion))
                store.draftTrigger = ""; store.draftExpansion = ""
            }
            List {
                ForEach(store.settings.snippets) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text("“\(s.trigger)”").bold()
                            Text(s.expansion).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.settings.snippets.removeAll { $0.id == s.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

struct StylesTab: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        Form {
            Picker("Default style", selection: $store.settings.defaultStyle) {
                ForEach(WritingStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Section("Per-app styles") {
                Toggle("Choose style from the app I'm dictating into", isOn: $store.settings.useActiveAppForStyle)
                Text("When on, LocalFlow reads only the frontmost app's identifier (e.g. com.apple.mail) to pick a style. It never reads window or document contents.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AppCategory.allCases, id: \.self) { cat in
                    Picker(cat.displayName, selection: Binding(
                        get: { store.settings.categoryStyles[cat] ?? store.settings.defaultStyle },
                        set: { store.settings.categoryStyles[cat] = $0 })) {
                        ForEach(WritingStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .disabled(!store.settings.useActiveAppForStyle)
                }
            }
            Section("App categories") {
                ForEach($store.settings.appRules) { $rule in
                    HStack {
                        Text(rule.bundleID).font(.caption.monospaced())
                        Spacer()
                        Picker("", selection: $rule.category) {
                            ForEach(AppCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.frame(width: 180)
                    }
                }
                Button("Add Running Apps") { addRunningApps() }
                Text("Adds each open app not listed yet as “Other”; change its category above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addRunningApps() {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { id in !store.settings.appRules.contains { $0.bundleID == id } && id != Bundle.main.bundleIdentifier }
        for id in ids.sorted() { store.settings.appRules.append(AppStyleRule(bundleID: id, category: .other)) }
    }
}

struct TryItTab: View {
    @ObservedObject var store: AppViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Type what you might say to preview how it will be formatted with the current settings.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $store.tryInput).frame(height: 100).border(Color.secondary.opacity(0.3))
            Text("Result").font(.headline)
            ScrollView {
                Text(store.preview(store.tryInput)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8).background(Color.secondary.opacity(0.08))
        }
    }
}
