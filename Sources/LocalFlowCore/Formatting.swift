import Foundation

// MARK: - Vocabulary (user dictionary + built-in technical casing)

enum Vocabulary {
    /// Safe in any context: these spellings are never ordinary words.
    static let general: [String: [String]] = [
        "JavaScript": ["javascript", "java script"],
        "TypeScript": ["typescript", "type script"],
        "GitHub": ["github", "git hub"],
        "GitLab": ["gitlab", "git lab"],
        "iPhone": ["iphone"], "iPad": ["ipad"], "macOS": ["macos", "mac os"], "iOS": ["ios"],
        "YouTube": ["youtube"], "LinkedIn": ["linkedin"], "ChatGPT": ["chatgpt", "chat gpt"],
        "OK": ["ok"],
    ]

    /// Applied in developer mode, where these readings are far more likely.
    static let developer: [String: [String]] = [
        "JSON": ["json", "jason"], "YAML": ["yaml", "yamel"], "API": ["api"], "APIs": ["apis"],
        "URL": ["url"], "URLs": ["urls"], "HTTP": ["http"], "HTTPS": ["https"], "SQL": ["sql"],
        "PostgreSQL": ["postgresql", "postgre sql", "postgres sql"], "Postgres": ["postgres", "post gress", "postgress"],
        "MySQL": ["mysql", "my sql", "my sequel"], "SQLite": ["sqlite", "sequel lite", "sql lite"],
        "npm": ["npm", "n p m"], "pnpm": ["pnpm"], "npx": ["npx"], "Node.js": ["node js", "nodejs", "node.js"],
        "Next.js": ["next js", "nextjs", "next.js"], "React": ["react"], "Vue": ["vue", "view js"],
        "SwiftUI": ["swiftui", "swift ui"], "Xcode": ["xcode", "x code"], "VS Code": ["vs code", "vscode", "v s code"],
        "Kubernetes": ["kubernetes", "cooper netties"], "kubectl": ["kubectl", "kube control", "kube cuddle", "cube control"],
        "Docker": ["docker"], "AWS": ["aws"], "GCP": ["gcp"], "CLI": ["cli"], "CSS": ["css"], "HTML": ["html"],
        "OAuth": ["oauth", "o auth"], "JWT": ["jwt"], "GraphQL": ["graphql", "graph ql"], "Redis": ["redis"],
        "PyTorch": ["pytorch", "pie torch", "py torch"], "NumPy": ["numpy", "num pie", "num py"],
        "pandas": ["pandas"], "Django": ["django", "jango"], "FastAPI": ["fastapi", "fast api"],
        "Python": ["python"], "Rust": ["rust"], "Kotlin": ["kotlin"], "Swift": ["swift"], "Java": ["java"],
        "Ruby": ["ruby"], "Go": ["golang"], "C++": ["c plus plus", "c++"], "C#": ["c sharp"],
        "Bash": ["bash"], "zsh": ["zsh", "z shell"], "Homebrew": ["homebrew", "home brew"],
        "Linux": ["linux"], "Ubuntu": ["ubuntu"], "regex": ["regex", "reg ex"], "stdout": ["stdout", "standard out"],
        "stderr": ["stderr", "standard error"], "localhost": ["localhost", "local host"], "UUID": ["uuid"],
        "LLM": ["llm"], "GPU": ["gpu"], "CPU": ["cpu"], "SDK": ["sdk"], "IDE": ["ide"], "PR": ["pr"],
        "CI/CD": ["ci cd", "ci/cd"], "README": ["readme", "read me"], "env": ["env"], "TODO": ["todo", "to do"],
        "Tailwind": ["tailwind"], "Vite": ["vite"], "webpack": ["webpack", "web pack"], "Jest": ["jest"],
        "async": ["async", "a sync"], "await": ["await"], "boolean": ["boolean"], "enum": ["enum", "e num"],
        "sudo": ["sudo", "pseudo"], "chmod": ["chmod", "ch mod"], "grep": ["grep"], "curl": ["curl"],
    ]

    static var promptTerms: [String] {
        ["JavaScript", "TypeScript", "GitHub", "JSON", "API", "npm", "kubectl", "PostgreSQL",
         "SwiftUI", "Xcode", "OAuth", "GraphQL", "PyTorch", "NumPy", "async", "await"]
    }

    static func apply(_ s: String, dictionary: [DictionaryEntry], developerMode: Bool) -> String {
        var rules: [(String, String)] = []
        // User entries win over built-ins: they are applied first and protected.
        for e in dictionary where !e.term.isEmpty {
            rules += e.corrections.filter { !$0.isEmpty }.map { ($0, e.term) }
            rules.append((e.term, e.term))
        }
        var builtins = general
        if developerMode { builtins.merge(developer) { a, _ in a } }
        let user = rules.count
        for (term, variants) in builtins { rules += variants.map { ($0, term) } }

        var t = s
        // Within each group, longer phrases first so "git hub" beats "git".
        let ordered = rules[..<user].sorted { $0.0.count > $1.0.count }
            + rules[user...].sorted { $0.0.count > $1.0.count }
        for (spoken, term) in ordered {
            let p = #"(?<![\w\x{E000}\x{E001}])"# + String.escapedPattern(spoken) + #"(?![\w\x{E001}]|\+)"#
            t = t.replacing(p, using: { _ in "\u{E002}" + term + "\u{E003}" })
        }
        // Collapse markers; nested markers come from a term containing a variant.
        t = t.replacing(#"\x{E002}+"#, with: "\u{E002}").replacing(#"\x{E003}+"#, with: "\u{E003}")
        return t
    }
}

/// Styles must not recase dictionary terms; terms are wrapped in E002/E003.
extension String {
    var withoutTermMarkers: String {
        replacingOccurrences(of: "\u{E002}", with: "").replacingOccurrences(of: "\u{E003}", with: "")
    }
}

// MARK: - Developer mode

enum Developer {
    static let caseCommands = ["camel case", "camelcase", "snake case", "pascal case", "kebab case",
                               "constant case", "screaming snake case", "all caps", "upper case", "lower case", "title case"]

    static let symbols: [(String, String, Glue)] = [
        ("double dash", "--", .right), ("dash dash", "--", .right),
        ("forward slash", "/", .both), ("back slash", "\\", .both), ("backslash", "\\", .both), ("slash", "/", .both),
        ("underscore", "_", .both), ("under score", "_", .both),
        ("dot", ".", .both), ("at sign", "@", .right), ("hash sign", "#", .right), ("hashtag", "#", .right),
        ("tilde", "~", .right), ("dollar sign", "$", .right),
        ("double equals", "==", .spaced), ("triple equals", "===", .spaced), ("not equals", "!=", .spaced),
        ("equals sign", "=", .spaced), ("equals", "=", .spaced), ("plus equals", "+=", .spaced),
        ("fat arrow", "=>", .spaced), ("arrow", "->", .spaced), ("pipe", "|", .spaced), ("ampersand", "&", .spaced),
        ("double colon", "::", .both), ("asterisk", "*", .none), ("percent sign", "%", .left),
        ("open bracket", "[", .right), ("close bracket", "]", .left), ("open brace", "{", .right),
        ("close brace", "}", .left), ("open curly", "{", .right), ("close curly", "}", .left),
        ("open angle", "<", .right), ("close angle", ">", .left), ("less than", "<", .spaced), ("greater than", ">", .spaced),
        ("backtick", "`", .none), ("back tick", "`", .none), ("dash", "-", .right), ("hyphen", "-", .both),
    ]

    enum Glue { case left, right, both, spaced, none }

    static func apply(_ s: String, protected: inout ProtectedText) -> String {
        var t = s
        // Case commands transform the words that follow, up to punctuation.
        let cmds = caseCommands.map(String.escapedPattern).joined(separator: "|")
        t = t.replacing(#"\b("# + cmds + #")[,:]?\s+([\w' ]+?)(?=[,.;:!?\n]|\s+(?:"# + cmds + #")\b|$)"#) { g in
            protected.protect(transformCase(command: g[1]!.lowercased(), words: g[2]!))
        }

        // Whisper sometimes writes the command into the identifier itself.
        t = t.replacing(#"\b(camelCase|snakeCase|pascalCase|kebabCase)([A-Z]\w*)"#, options: []) { g in
            let words = g[2]!.replacing(#"([a-z0-9])([A-Z])"#, with: "$1 $2", options: [])
            let command = g[1]!.replacing(#"([a-z])([A-Z])"#, with: "$1 $2", options: []).lowercased()
            return protected.protect(transformCase(command: command, words: words))
        }

        // Symbol words: mark their glue with sentinels, then remove spaces.
        for (spoken, symbol, glue) in symbols {
            let p = #"[,]?\s*\b"# + String.escapedPattern(spoken) + #"\b[,]?"#
            let rep: String
            switch glue {
            case .both: rep = "\u{E010}" + symbol + "\u{E011}"
            case .right: rep = " " + symbol + "\u{E011}"
            case .left: rep = "\u{E010}" + symbol + " "
            case .spaced: rep = " " + symbol + " "
            case .none: rep = " " + symbol + " "
            }
            t = t.replacing(p, using: { _ in rep })
        }
        t = t.replacing(#"\s*\x{E010}"#, with: "").replacing(#"\x{E011}\s*"#, with: "")
        // Whisper often hears a file name as two sentences: "index. Ts".
        t = t.replacing(#"\b(\w+)\.\s+(js|ts|tsx|jsx|py|rb|go|rs|md|json|yaml|yml|toml|swift|sh|txt|html|css|env)\b"#, with: "$1.$2")
        return t
    }

    static func transformCase(command: String, words raw: String) -> String {
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "'" }).map { $0.lowercased() }
        guard !words.isEmpty else { return "" }
        switch command {
        case "camel case", "camelcase":
            return words[0] + words.dropFirst().map(\.capitalized).joined()
        case "pascal case":
            return words.map(\.capitalized).joined()
        case "snake case":
            return words.joined(separator: "_")
        case "kebab case":
            return words.joined(separator: "-")
        case "constant case", "screaming snake case":
            return words.joined(separator: "_").uppercased()
        case "all caps", "upper case":
            return words.joined(separator: " ").uppercased()
        case "lower case":
            return words.joined(separator: " ")
        case "title case":
            return words.map(\.capitalized).joined(separator: " ")
        default:
            return raw
        }
    }
}

// MARK: - Writing styles

enum Styles {
    static let informal: [(String, String)] = [
        ("gonna", "going to"), ("wanna", "want to"), ("gotta", "have to"), ("kinda", "kind of"),
        ("sorta", "sort of"), ("dunno", "don't know"), ("ya know", "you know"), ("lemme", "let me"),
    ]
    static let transitions = ["Also", "Additionally", "Next", "Finally", "Anyway", "However", "Separately",
                              "Lastly", "In addition", "Moving on", "Regarding", "On another note", "Secondly", "Meanwhile"]

    static func apply(_ s: String, style: WritingStyle) -> String {
        var t = s
        switch style {
        case .formal, .professionalEmail, .technical:
            for (a, b) in informal { t = t.replacing(#"\b"# + a + #"\b"#, with: b) }
            t = sentenceCase(t)
            t = ensureTerminalPunctuation(t)
            if style == .technical { t = t.replacing(#"!(?=\s|$)"#, with: ".") }
            if style != .technical { t = paragraphs(t) }
            if style == .professionalEmail { t = emailLayout(t) }
        case .casual:
            t = sentenceCase(t)
            t = dropFinalPeriod(t)
        case .veryCasual:
            t = sentenceCase(t)
            t = t.replacing(#"(^|[.!?]\s+|\n)([A-Z])(?![A-Z\x{E003}])"#, options: []) { g in g[1]! + g[2]!.lowercased() }
            t = t.replacing(#"\bI\b"#, with: "i", options: [])
            t = t.replacing(#"[.](?=\s|$)"#, with: "", options: [])
        case .excited:
            t = sentenceCase(t)
            t = ensureTerminalPunctuation(t)
            // Upbeat sentences and the closing sentence end with "!".
            t = t.replacing(#"(\b(?:thanks|thank you|great|awesome|amazing|love|congrats|congratulations|excited|can't wait|wow)\b[^.!?\n]*)\.(?=\s|$)"#, with: "$1!")
            t = t.replacing(#"\.$"#, with: "!", options: [])
        }
        return t.withoutTermMarkers
    }

    static func sentenceCase(_ s: String) -> String {
        var t = s.replacing(#"\bi\b(?!\.)"#, with: "I", options: [])
            .replacing(#"\bi('m|'ll|'d|'ve)\b"#, with: "I$1", options: [])
        t = t.replacing(#"(^\s*|[.!?…]\s+|\n\s*|^\d+\.\s+|\n\d+\.\s+)([a-z])"#, options: []) { g in g[1]! + g[2]!.uppercased() }
        return t
    }

    static func ensureTerminalPunctuation(_ s: String) -> String {
        // Lists keep their own lines; otherwise end prose with a period.
        guard let last = s.trimmingCharacters(in: .whitespacesAndNewlines).withoutTermMarkers.last else { return s }
        if last.isLetter || last.isNumber || last == "\u{201D}" || last == ")" {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastLine = trimmed.split(separator: "\n").last, lastLine.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                return trimmed
            }
            return trimmed + "."
        }
        return s
    }

    static func dropFinalPeriod(_ s: String) -> String {
        s.replacing(#"(?<!\.)\.\s*$"#, with: "", options: [])
    }

    /// Breaks long prose into paragraphs at topic transitions.
    static func paragraphs(_ s: String) -> String {
        guard !s.contains("\n") else { return s }
        let sentences = s.replacing(#"([.!?])\s+(?=[A-Z\x{E000}\x{E002}])"#, with: "$1\u{1F}", options: [])
            .split(separator: "\u{1F}").map(String.init)
        guard sentences.count >= 5 else { return s }
        var out = ""
        var inParagraph = 0
        for sentence in sentences {
            let plain = sentence.withoutTermMarkers
            let isTransition = transitions.contains { plain.hasPrefix($0 + " ") || plain.hasPrefix($0 + ",") }
            if !out.isEmpty {
                if (isTransition && inParagraph >= 2) || inParagraph >= 4 {
                    out += "\n\n"
                    inParagraph = 0
                } else {
                    out += " "
                }
            }
            out += sentence
            inParagraph += 1
        }
        return out
    }

    /// Puts a greeting and a sign-off on their own lines.
    static func emailLayout(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n\n", with: "\u{1E}")
        t = t.replacing(#"^((?:hi|hello|hey|dear|good (?:morning|afternoon|evening))\b[^,.!\n]{0,40})[,.!]\s*"#,
                        using: { g in g[1]! + ",\n\n" })
        t = t.replacing(#"[\s\x{1E}]*\b((?:thanks again|many thanks|thank you|thanks|best regards|kind regards|warm regards|regards|best|cheers|sincerely))[,.!]?\s+([A-Z\x{E002}][\w\x{E003}]*(?:\s+[A-Z][\w]*)?)[.!]?$"#,
                        using: { g in "\n\n" + g[1]!.capitalizedFirst(if: true) + ",\n" + g[2]! })
        t = t.replacing(#"[\s\x{1E}]*\b((?:thank you|thanks|best regards|kind regards|regards|cheers|sincerely))[.!]?$"#,
                        using: { g in "\n\n" + g[1]!.capitalizedFirst(if: true) + "," })
        return t.replacingOccurrences(of: "\u{1E}", with: "\n\n")
    }
}
