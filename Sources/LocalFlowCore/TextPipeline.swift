import Foundation

/// Options for one dictation, resolved from `Settings` and the (optional,
/// user-permitted) active-app category.
public struct PipelineOptions: Sendable {
    public var style: WritingStyle
    public var developerMode: Bool
    public var removeFillers: Bool
    public var backtracking: Bool
    public var spokenPunctuation: Bool
    public var autoLists: Bool
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]

    public init(style: WritingStyle = .formal, developerMode: Bool = false,
                removeFillers: Bool = true, backtracking: Bool = true,
                spokenPunctuation: Bool = true, autoLists: Bool = true,
                dictionary: [DictionaryEntry] = [], snippets: [Snippet] = []) {
        self.style = style
        self.developerMode = developerMode || style == .technical
        self.removeFillers = removeFillers
        self.backtracking = backtracking
        self.spokenPunctuation = spokenPunctuation
        self.autoLists = autoLists
        self.dictionary = dictionary
        self.snippets = snippets
    }

    public init(settings: Settings, bundleID: String?) {
        self.init(
            style: settings.style(forBundleID: bundleID),
            developerMode: settings.developerModeActive(forBundleID: bundleID),
            removeFillers: settings.removeFillers,
            backtracking: settings.backtracking,
            spokenPunctuation: settings.spokenPunctuation,
            autoLists: settings.autoLists,
            dictionary: settings.dictionary,
            snippets: settings.snippets)
    }
}

/// Turns a raw speech-model transcript into the text that gets inserted.
/// Deterministic and rule-based: it never calls a network service and never
/// produces anything but text.
public enum TextPipeline {
    public static func process(_ raw: String, options: PipelineOptions) -> String {
        var text = Cleanup.stripArtifacts(raw)
        guard !text.isEmpty else { return "" }

        // Snippet expansions are protected so later stages leave them verbatim.
        var protected = ProtectedText()
        text = Snippets.expand(text, snippets: options.snippets, protected: &protected)

        if options.backtracking { text = Backtracking.apply(text) }
        // Developer symbols first: "dash dash" must not look like a stutter.
        if options.developerMode { text = Developer.apply(text, protected: &protected) }
        if options.removeFillers { text = Fillers.remove(text) }
        if options.spokenPunctuation { text = SpokenPunctuation.apply(text) }
        text = Vocabulary.apply(text, dictionary: options.dictionary,
                                developerMode: options.developerMode)
        if options.autoLists { text = Lists.apply(text) }
        text = Cleanup.normalizeSpacing(text)
        text = Styles.apply(text, style: options.style)
        text = protected.restore(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words worth biasing the speech model toward (dictionary + dev vocabulary).
    public static func recognitionPrompt(options: PipelineOptions) -> String {
        var terms = options.dictionary.map(\.term)
        if options.developerMode { terms += Vocabulary.promptTerms }
        var seen = Set<String>()
        terms = terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !terms.isEmpty else { return "" }
        return "Vocabulary: " + terms.prefix(80).joined(separator: ", ") + "."
    }
}

/// Placeholders for text that must survive later stages untouched.
struct ProtectedText {
    private(set) var values: [String] = []

    mutating func protect(_ s: String) -> String {
        values.append(s)
        return "\u{E000}\(values.count - 1)\u{E001}"
    }

    func restore(_ text: String) -> String {
        var out = text
        for (i, v) in values.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: v)
        }
        return out
    }
}

// MARK: - Regex helpers

extension String {
    func replacing(_ pattern: String, with template: String,
                   options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self),
                                           withTemplate: template)
    }

    func replacing(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive],
                   using transform: ([String?]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let ns = self as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String? in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func escapedPattern(_ phrase: String) -> String {
        phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s,]+")
    }
}

// MARK: - Cleanup

enum Cleanup {
    /// Removes non-speech annotations Whisper emits ("[BLANK_AUDIO]", "(music)").
    static func stripArtifacts(_ s: String) -> String {
        s.replacing(#"\[[^\]]*\]|\((?:music|applause|laughter|silence|inaudible|blank_audio)[^)]*\)|♪"#, with: " ")
            .replacing(#"\s+"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeSpacing(_ s: String) -> String {
        s.replacing(#"[ \t]+"#, with: " ")
            .replacing(#" +([,.;:!?)\]}])"#, with: "$1")
            .replacing(#"([(\[{]) +"#, with: "$1")
            .replacing(#"([,;:])(?=[A-Za-z])"#, with: "$1 ")
            .replacing(#",\s*([.!?])"#, with: "$1")
            .replacing(#"([.!?]),"#, with: "$1")
            .replacing(#",{2,}"#, with: ",")
            .replacing(#"(?<![.])\.{2}(?![.])"#, with: ".")
            .replacing(#" *\n *"#, with: "\n")
            .replacing(#"\n{3,}"#, with: "\n\n")
            .replacing(#"^[\s,;]+"#, with: "")
    }
}

// MARK: - Snippets

enum Snippets {
    static func expand(_ text: String, snippets: [Snippet], protected: inout ProtectedText) -> String {
        var out = text
        // Longest trigger first so "my work address" wins over "my address".
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = s.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { continue }
            let pattern = #"(?<![\w-])"# + String.escapedPattern(trigger) + #"(?![\w-])[.!?]?"#
            out = out.replacing(pattern) { _ in protected.protect(s.expansion) }
        }
        return out
    }
}

// MARK: - Backtracking (course corrections spoken mid-sentence)

enum Backtracking {
    /// Markers that always signal a correction.
    static let strong = [
        "no wait", "wait no", "no, wait", "wait, no", "sorry, i meant", "sorry i meant",
        "i meant", "or rather", "correction", "let me rephrase", "make that",
    ]
    /// Markers that only count as corrections at a clause boundary (after a comma
    /// or sentence break), since they are common in ordinary speech.
    static let weak = ["actually", "i mean", "sorry", "no", "rather", "oops"]
    /// Phrases that discard the sentence spoken before them.
    static let discard = ["scratch that", "delete that", "strike that", "never mind", "nevermind", "forget that"]

    static func apply(_ input: String) -> String {
        var text = input
        // Discard commands: drop the preceding sentence (or everything before
        // them in the current sentence) along with the command itself.
        for phrase in discard {
            let p = #"([^.!?]*[.!?]?)\s*\b"# + String.escapedPattern(phrase) + #"\b[.,!]?\s*"#
            while let r = text.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                text.replaceSubrange(r, with: "")
            }
        }

        text = ValueCorrection.apply(text)

        var changed = true
        var guardCount = 0
        while changed && guardCount < 10 {
            changed = false
            guardCount += 1
            if let next = correctOnce(text) { text = next; changed = true }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func correctOnce(_ text: String) -> String? {
        let strongAlt = strong.map(String.escapedPattern).joined(separator: "|")
        let weakAlt = weak.map(String.escapedPattern).joined(separator: "|")
        // A marker after a comma/dash, a strong marker anywhere, or a marker
        // opening a new sentence (Whisper often hears "2pm. Actually 3pm.").
        let pattern = #"(?:[,;]|\s-+)\s*(?:"# + strongAlt + "|" + weakAlt + #")\b[,]?\s+|\s(?:"# + strongAlt
            + #")\b[,]?\s+|[.!?]\s+(?:"# + strongAlt + "|" + weakAlt + #")\b[,]?\s+"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let opensSentence = ".!?".contains(ns.substring(with: NSRange(location: m.range.location, length: 1)))
            let marker = ns.substring(with: m.range).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;- ").union(.whitespaces))
            let before = ns.substring(to: m.range.location)
            let afterAll = ns.substring(from: m.range.location + m.range.length)
            // The correction runs to the end of its sentence.
            let endIdx = afterAll.firstIndex(where: { ".!?\n".contains($0) }) ?? afterAll.endIndex
            let replacement = String(afterAll[..<endIdx]).trimmingCharacters(in: .whitespaces)
            let rest = String(afterAll[endIdx...])
            guard !replacement.isEmpty else { continue }
            // A sentence that merely starts with "Actually," is ordinary prose
            // unless it is a short fragment.
            if opensSentence && !strong.contains(marker) && replacement.split(separator: " ").count > 3 { continue }
            // Weak markers ("no", "sorry") with a long tail are usually prose,
            // not a correction; leaving the text alone beats mangling it.
            if !strong.contains(marker) && replacement.split(separator: " ").count > 6 { continue }

            // Only the current sentence of `before` can be corrected.
            let sentenceStart = before.lastIndex(where: { ".!?\n".contains($0) }).map { before.index(after: $0) } ?? before.startIndex
            let head = String(before[..<sentenceStart])
            let clause = String(before[sentenceStart...])
            guard let fixed = merge(clause: clause, replacement: replacement) else { continue }
            return head + fixed + rest
        }
        return nil
    }

    /// Splices `replacement` into `clause`, replacing the part it corrects.
    static func merge(clause: String, replacement: String) -> String? {
        let words = clause.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let repl = replacement.split(separator: " ").map(String.init)
        guard !words.isEmpty, let first = repl.first else { return nil }
        let key = normalize(first)

        // 1. The correction restarts from a word already said ("to John, no, to Sarah").
        if let idx = words.lastIndex(where: { normalize($0) == key }) {
            if idx == 0 {
                return (repl).joined(separator: " ").capitalizedFirst(if: startsCapitalized(words))
            }
            return (words[..<idx] + repl).joined(separator: " ")
        }
        // 2. The correction restarts the whole clause with a new subject
        //    ("I'll go, actually we'll stay home").
        if repl.count >= 3, subjects.contains(key) {
            return repl.joined(separator: " ").capitalizedFirst(if: startsCapitalized(words))
        }
        // 3. Replace the last word of the same kind and what follows it:
        //    numbers for numbers ("2pm, no wait, 3pm on Thursday"), names for
        //    names ("on Tuesday, I meant Wednesday").
        let hasDigit: (String) -> Bool = { $0.contains(where: \.isNumber) }
        let isName: (String) -> Bool = { $0.first?.isUppercase == true && $0 != "I" }
        let kind: ((String) -> Bool)? = hasDigit(first) ? hasDigit : (isName(first) ? isName : nil)
        if let kind, let idx = words.indices.last(where: { $0 > 0 && kind(words[$0]) }) {
            return (words[..<idx] + repl).joined(separator: " ")
        }
        // 4. Otherwise replace as many trailing words as the correction's head
        //    ("buy apples, sorry, pears and milk" → "buy pears and milk").
        let head = repl.prefix(while: { !connectors.contains(normalize($0)) }).count
        let n = min(max(head, 1), words.count - 1)
        guard n > 0 else { return repl.joined(separator: " ").capitalizedFirst(if: startsCapitalized(words)) }
        return (words.dropLast(n) + repl).joined(separator: " ")
    }

    private static let subjects: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "let's", "i'll", "we'll", "i'm", "we're", "there"]
    private static let connectors: Set<String> = ["and", "or", "on", "at", "in", "to", "for", "with", "by", "from", "of"]

    private static func normalize(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func startsCapitalized(_ words: [String]) -> Bool {
        words.first?.first?.isUppercase ?? false
    }
}

/// Corrections of a single value, as people actually say them:
/// "at 2pm no no 6pm", "at 3pm. No, no, not 3pm. At 6pm.",
/// "at 2pm tomorrow. No, let it be, not 2pm, make it 6pm."
/// The earlier value is replaced by the new one of the same kind (time,
/// number, weekday, relative day) and the correction words are dropped.
enum ValueCorrection {
    enum Kind { case time, number, relativeDay }

    struct Token {
        let range: NSRange
        let text: String
        let kind: Kind
    }

    static let dayWords = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
    /// Longest alternatives first so "day after tomorrow" beats "tomorrow".
    static let valuePattern = #"\b(?:the day after tomorrow|day after tomorrow|the day before yesterday|day before yesterday|(?:next|this|coming) (?:week|weekend|month|"# + dayWords
        + #")|\d{1,2}(?::\d{2})?\s?(?:am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|noon|midnight|\d+(?:\.\d+)?%?|(?:"# + dayWords
        + #")|today|tomorrow|tonight|yesterday|weekend)(?![\w])"#
    static let markerPattern = #"(?:^|(?<=[\s,.;!?]))(?:no|nope|not|wait|actually|sorry|rather|make it|i mean|i meant|change (?:it|that) to)\b"#
    /// Words that may sit between the correction marker and the new value.
    static let filler: Set<String> = [
        "no", "nope", "not", "wait", "actually", "sorry", "i", "mean", "meant", "make", "it", "let", "be",
        "rather", "instead", "at", "on", "by", "change", "to", "that", "oh", "okay", "ok", "so", "the",
        "around", "let's", "do", "say", "um", "uh", "yeah", "hmm", "better", "lets", "and", "then",
    ]

    static func kind(of s: String) -> Kind {
        let l = s.lowercased()
        if l.range(of: #"am|pm|a\.m\.|p\.m\.|:|noon|midnight"#, options: .regularExpression) != nil { return .time }
        if l.contains("today") || l.contains("tomorrow") || l.contains("yesterday") || l.contains("tonight")
            || l.hasPrefix("next ") || l.hasPrefix("this ") || l.hasPrefix("coming ") || l.contains("weekend") {
            return .relativeDay
        }
        if l.first?.isLetter == true { return .relativeDay } // weekdays and relative days interchange
        return .number
    }

    static func apply(_ input: String) -> String {
        var text = input
        for _ in 0..<5 {
            guard let next = correctOnce(text) else { break }
            text = next
        }
        return text
    }

    private static func correctOnce(_ text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let valueRe = try? NSRegularExpression(pattern: valuePattern, options: .caseInsensitive),
              let markerRe = try? NSRegularExpression(pattern: markerPattern, options: .caseInsensitive) else { return nil }
        let values = valueRe.matches(in: text, range: full).map {
            Token(range: $0.range, text: ns.substring(with: $0.range), kind: kind(of: ns.substring(with: $0.range)))
        }
        for marker in markerRe.matches(in: text, range: full) {
            let mStart = marker.range.location
            // The new value: the first value after the marker reached only
            // through correction words (and repeats of the old value).
            for y in values where y.range.location >= mStart + marker.range.length {
                guard let x = values.last(where: {
                    $0.range.location + $0.range.length <= mStart && $0.kind == y.kind
                        && $0.text.lowercased() != y.text.lowercased()
                }) else { continue } // e.g. the "3pm" in "not 3pm": keep looking
                // The old value must be close: same or previous sentence, ≤ 12 words back.
                let between = ns.substring(with: NSRange(location: x.range.location + x.range.length,
                                                         length: mStart - x.range.location - x.range.length))
                guard between.split(whereSeparator: \.isWhitespace).count <= 12,
                      between.filter({ ".!?".contains($0) }).count <= 1 else { break }
                let gap = ns.substring(with: NSRange(location: mStart, length: y.range.location - mStart))
                let gapWords = gap.lowercased().replacingOccurrences(of: x.text.lowercased(), with: " ")
                    .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
                    .filter { !$0.isEmpty }
                guard gapWords.allSatisfy(filler.contains) else { break }
                // A bare "not" only corrects when it names the old value ("not 3pm").
                let markerWord = ns.substring(with: marker.range).lowercased()
                if markerWord == "not", !gap.lowercased().contains(x.text.lowercased()) { break }

                // Keep real words between the old value and the marker, minus
                // trailing hesitations ("tomorrow, oh not 3pm").
                var keepWords = between.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;!?")))
                    .split(separator: " ").map(String.init)
                while let last = keepWords.last,
                      filler.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                    keepWords.removeLast()
                }
                let keep = keepWords.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",.;!? "))
                let head = ns.substring(to: x.range.location)
                let tail = ns.substring(from: y.range.location + y.range.length)
                return head + y.text + (keep.isEmpty ? "" : " " + keep) + tail
            }
        }
        return nil
    }
}

extension String {
    func capitalizedFirst(if condition: Bool) -> String {
        guard condition, let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}

// MARK: - Filler words

enum Fillers {
    static func remove(_ s: String) -> String {
        var t = s
        // Pure hesitation sounds, anywhere.
        t = t.replacing(#"(?<![\w'])(?:u+[hm]+|e+r+m*|a+h+|h+m+|m+h*m+|uh-huh)(?![\w'])[,.]?\s*"#, with: "")
        // Discourse fillers only when set off by commas or at the start.
        t = t.replacing(#"(?:(?<=^)|(?<=[,.!?]\s)|,\s)(?:you know|like|i mean|basically|so|well|okay so|kind of|sort of)[,]\s+"#,
                        using: { g in g[0]!.hasPrefix(",") ? " " : "" })
        t = t.replacing(#",\s*you know(?=[,.!?]|$)"#, with: "")
        // Immediate stutter repeats ("the the", "I I").
        t = t.replacing(#"\b(\w+)(?:\s+\1\b)+"#, with: "$1")
        // Capitalize again if we stripped the first word.
        if let f = t.first, f.isLowercase, let sf = s.first, sf.isUppercase {
            t = f.uppercased() + t.dropFirst()
        }
        return t
    }
}

// MARK: - Spoken punctuation and formatting commands

enum SpokenPunctuation {
    static let marks: [(String, String)] = [
        ("new paragraph", "\n\n"), ("next paragraph", "\n\n"),
        ("new line", "\n"), ("next line", "\n"), ("line break", "\n"),
        ("question mark", "?"), ("exclamation point", "!"), ("exclamation mark", "!"),
        ("full stop", "."), ("semicolon", ";"), ("semi colon", ";"),
        ("ellipsis", "…"), ("dot dot dot", "…"),
        ("open quote", " \u{201C}"), ("close quote", "\u{201D} "), ("end quote", "\u{201D} "), ("unquote", "\u{201D} "),
        ("open parenthesis", " ("), ("open paren", " ("), ("close parenthesis", ") "), ("close paren", ") "),
        ("em dash", " — "),
    ]

    static func apply(_ s: String) -> String {
        var t = s
        for (spoken, mark) in marks {
            let p = #"[,.]?\s*\b"# + String.escapedPattern(spoken) + #"\b[,.]?\s*"#
            t = t.replacing(p, with: NSRegularExpression.escapedTemplate(for: mark))
        }
        // Ambiguous words: only treat as punctuation when not used as nouns
        // ("a period of time", "the colon").
        let ambiguous = [("comma", ","), ("period", "."), ("colon", ":"), ("exclamation", "!")]
        for (spoken, mark) in ambiguous {
            let p = #"(?<!\b(?:a|the|this|that|one|each|every|trial|grace|time|my|your|his|her|our|their))[,.]?\s+\b"# + spoken + #"\b[,.]?(?=\s|$)"#
            t = t.replacing(p, with: mark)
        }
        // Capitalize after sentence punctuation and line breaks we inserted.
        t = t.replacing(#"([.!?…]\s+|\n+\s*)([a-z])"#, options: []) { g in g[1]! + g[2]!.uppercased() }
        return t
    }
}

// MARK: - Spoken lists

enum Lists {
    static let ordinals: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "firstly": 1, "secondly": 2, "thirdly": 3, "fourthly": 4, "fifthly": 5,
    ]

    static let cardinals: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    /// "my list: one milk two eggs three bread" → numbered lines. Requires the
    /// sequence to start at one and count up, each marker at a clause start.
    static func apply(_ s: String) -> String {
        // Digits and cardinals may be followed by a space; ordinals ("first")
        // need punctuation so prose like "first line" is not a list.
        let ordinalWords = ordinals.keys.filter { !cardinals.contains($0) }.sorted { $0.count > $1.count }.joined(separator: "|")
        let cardinalWords = cardinals.sorted { $0.count > $1.count }.joined(separator: "|")
        let markerPattern = #"(?:^|(?<=[\s,.:;]))(?:(?:number\s+)?(?:\d{1,2}|"# + cardinalWords + #")(?:[.):,]|\s)|(?:"# + ordinalWords + #")[,:])\s*"#
        guard let re = try? NSRegularExpression(pattern: markerPattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))

        // Find the longest run of markers counting 1, 2, 3...
        var run: [NSTextCheckingResult] = []
        var runAtBoundary = false
        for m in matches {
            let token = ns.substring(with: m.range).lowercased()
                .replacingOccurrences(of: "number", with: "")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".):,")))
            let value = Int(token) ?? ordinals[token] ?? 0
            // Marker must sit at the start or after punctuation / a list item.
            let prefix = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            let atBoundary = prefix.isEmpty || ",.:;\n".contains(prefix.last!)
            if value == run.count + 1 && !run.isEmpty {
                run.append(m)
            } else if value == 1 {
                if run.count >= 2 && (runAtBoundary || run.count >= 3) { break }
                run = [m]
                runAtBoundary = atBoundary
            }
        }
        // A list introduced mid-sentence needs three items to be convincing.
        guard run.count >= 3 || (run.count == 2 && runAtBoundary) else { return s }

        var items: [String] = []
        for (i, m) in run.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < run.count ? run[i + 1].range.location : ns.length
            var item = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            if i == run.count - 1, let dot = item.range(of: #"[.!?]\s+[A-Z]"#, options: .regularExpression) {
                // Trailing prose after the last item stays as its own paragraph.
                let tail = String(item[item.index(after: dot.lowerBound)...]).trimmingCharacters(in: .whitespaces)
                item = String(item[..<item.index(after: dot.lowerBound)])
                items.append(item)
                return assemble(ns: ns, first: run[0], items: items, tail: tail)
            }
            items.append(item)
        }
        return assemble(ns: ns, first: run[0], items: items, tail: "")
    }

    private static func assemble(ns: NSString, first: NSTextCheckingResult, items: [String], tail: String) -> String {
        var intro = ns.substring(to: first.range.location).trimmingCharacters(in: .whitespaces)
        if !intro.isEmpty {
            intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            if !intro.hasSuffix(":") && !intro.hasSuffix(".") { intro += ":" }
            intro += "\n"
        }
        let lines = items.enumerated().map { i, item -> String in
            let cleaned = item.trimmingCharacters(in: CharacterSet(charactersIn: ".")).trimmingCharacters(in: .whitespaces)
            return "\(i + 1). " + cleaned.capitalizedFirst(if: true)
        }
        return intro + lines.joined(separator: "\n") + (tail.isEmpty ? "" : "\n\n" + tail)
    }
}
