import Foundation

/// A dictionary entry. A plain `term` teaches spelling and casing (and biases
/// the speech model); `corrections` are misrecognitions rewritten to `term`.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var term: String
    public var corrections: [String]

    public init(id: UUID = UUID(), term: String, corrections: [String] = []) {
        self.id = id
        self.term = term
        self.corrections = corrections
    }
}

/// A spoken trigger phrase that expands into a block of text.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case formal, casual, veryCasual, excited, professionalEmail, technical

    public var displayName: String {
        switch self {
        case .formal: "Formal — caps + punctuation"
        case .casual: "Casual — caps + less punctuation"
        case .veryCasual: "Very casual — no caps + less punctuation"
        case .excited: "Excited — more exclamations"
        case .professionalEmail: "Professional email — greeting, paragraphs, sign-off"
        case .technical: "Technical — precise, developer formatting"
        }
    }
}

/// App categories a style can be assigned to, mirroring the context classes
/// the user configures (not inferred from document contents).
public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case personalMessages, workMessages, email, coding, other

    public var displayName: String {
        switch self {
        case .personalMessages: "Personal messages"
        case .workMessages: "Work messages"
        case .email: "Email"
        case .coding: "Coding"
        case .other: "Other"
        }
    }
}

/// A modifier key held for push-to-talk.
public enum PushToTalkKey: String, Codable, CaseIterable, Sendable {
    case fn, rightOption, rightCommand, rightControl

    public var displayName: String {
        switch self {
        case .fn: "Fn (🌐)"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        }
    }
}

/// A key plus modifier chord, using macOS virtual key codes and modifier names.
public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var command: Bool
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    /// Chord is pressed while the push-to-talk key is held (e.g. Fn+Space).
    public var withPushToTalkKey: Bool

    public init(keyCode: UInt16, command: Bool = false, control: Bool = false,
                option: Bool = false, shift: Bool = false, withPushToTalkKey: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
        self.withPushToTalkKey = withPushToTalkKey
    }

    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
    public static let keyV: UInt16 = 9
    public static let keyC: UInt16 = 8

    public var displayName: String {
        var s = ""
        if withPushToTalkKey { s += "PTT+" }
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += KeyChord.keyName(keyCode)
        return s
    }

    static func keyName(_ code: UInt16) -> String {
        switch code {
        case 49: "Space"
        case 53: "Esc"
        case 9: "V"
        case 8: "C"
        case 2: "D"
        case 15: "R"
        case 36: "Return"
        default: "Key\(code)"
        }
    }
}

public struct Shortcuts: Codable, Equatable, Sendable {
    public var pushToTalk: PushToTalkKey = .fn
    public var handsFree: KeyChord = KeyChord(keyCode: KeyChord.space, withPushToTalkKey: true)
    public var cancel: KeyChord = KeyChord(keyCode: KeyChord.escape)
    public var pasteLast: KeyChord = KeyChord(keyCode: KeyChord.keyV, command: true, control: true)
    public var copyLast: KeyChord = KeyChord(keyCode: KeyChord.keyC, command: true, control: true)

    public init() {}

    public static let handsFreePresets: [KeyChord] = [
        KeyChord(keyCode: KeyChord.space, withPushToTalkKey: true),
        KeyChord(keyCode: KeyChord.space, control: true, option: true),
        KeyChord(keyCode: 2, command: true, option: true), // ⌥⌘D
    ]
}

public struct AppStyleRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var category: AppCategory

    public init(id: UUID = UUID(), bundleID: String, category: AppCategory) {
        self.id = id
        self.bundleID = bundleID
        self.category = category
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var shortcuts = Shortcuts()
    /// Whisper language code, "auto", or "hinglish" (English and Hindi,
    /// always written in Roman letters).
    public var language = "hinglish"
    public var playSounds = true
    public var removeFillers = true
    public var backtracking = true
    public var spokenPunctuation = true
    public var autoLists = true
    public var developerMode = false
    public var defaultStyle: WritingStyle = .formal
    public var categoryStyles: [AppCategory: WritingStyle] = [
        .personalMessages: .casual,
        .workMessages: .formal,
        .email: .professionalEmail,
        .coding: .technical,
        .other: .formal,
    ]
    /// Read only the frontmost app's bundle identifier (never its contents) to
    /// pick a style. Off until the user turns it on.
    public var useActiveAppForStyle = false
    public var appRules: [AppStyleRule] = AppStyleRule.defaults
    public var dictionary: [DictionaryEntry] = []
    public var snippets: [Snippet] = []
    public var keepHistory = true
    public var maxRecordingSeconds: Double = 20 * 60
    public var showDockIcon = false
    /// A small always-visible bar at the bottom of the screen when idle.
    public var showIdleBar = false
    /// Unload the speech model after this many minutes without dictation to
    /// free its memory (~1.9 GB); it reloads when you next press the
    /// shortcut. 0 keeps it loaded.
    public var idleUnloadMinutes = 15

    public init() {}

    public func style(forBundleID bundleID: String?) -> WritingStyle {
        guard useActiveAppForStyle, let bundleID,
              let rule = appRules.first(where: { $0.bundleID == bundleID })
        else { return defaultStyle }
        return categoryStyles[rule.category] ?? defaultStyle
    }

    public func developerModeActive(forBundleID bundleID: String?) -> Bool {
        if developerMode { return true }
        guard useActiveAppForStyle, let bundleID else { return false }
        return appRules.first(where: { $0.bundleID == bundleID })?.category == .coding
    }

    // Decode leniently so settings written by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        shortcuts = try c.decodeIfPresent(Shortcuts.self, forKey: .shortcuts) ?? d.shortcuts
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        backtracking = try c.decodeIfPresent(Bool.self, forKey: .backtracking) ?? d.backtracking
        spokenPunctuation = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation) ?? d.spokenPunctuation
        autoLists = try c.decodeIfPresent(Bool.self, forKey: .autoLists) ?? d.autoLists
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? d.developerMode
        defaultStyle = try c.decodeIfPresent(WritingStyle.self, forKey: .defaultStyle) ?? d.defaultStyle
        categoryStyles = try c.decodeIfPresent([AppCategory: WritingStyle].self, forKey: .categoryStyles) ?? d.categoryStyles
        useActiveAppForStyle = try c.decodeIfPresent(Bool.self, forKey: .useActiveAppForStyle) ?? d.useActiveAppForStyle
        appRules = try c.decodeIfPresent([AppStyleRule].self, forKey: .appRules) ?? d.appRules
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? d.dictionary
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? d.keepHistory
        maxRecordingSeconds = try c.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds) ?? d.maxRecordingSeconds
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        showIdleBar = try c.decodeIfPresent(Bool.self, forKey: .showIdleBar) ?? d.showIdleBar
        idleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
    }
}

extension AppStyleRule {
    public static let defaults: [AppStyleRule] = ([
        ("com.apple.MobileSMS", .personalMessages),
        ("net.whatsapp.WhatsApp", .personalMessages),
        ("ru.keepcoder.Telegram", .personalMessages),
        ("com.hnc.Discord", .personalMessages),
        ("com.tinyspeck.slackmacgap", .workMessages),
        ("com.microsoft.teams2", .workMessages),
        ("com.apple.mail", .email),
        ("com.microsoft.Outlook", .email),
        ("com.apple.Terminal", .coding),
        ("com.googlecode.iterm2", .coding),
        ("com.microsoft.VSCode", .coding),
        ("com.todesktop.230313mzl4w4u92", .coding), // Cursor
        ("com.exafunction.windsurf", .coding),
        ("com.apple.dt.Xcode", .coding),
        ("dev.zed.Zed", .coding),
    ] as [(String, AppCategory)]).map { AppStyleRule(bundleID: $0.0, category: $0.1) }
}

/// Atomic JSON persistence in the user's Application Support directory.
public struct JSONStore<Value: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
