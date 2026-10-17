import Foundation

/// Converts Hindi written in Devanagari into the Roman-letter Hinglish people
/// type in chats ("मुझे कुछ समझ नहीं आ रहा" → "mujhe kuch samajh nahi aa raha"),
/// and restores English words Whisper spelled in Devanagari ("मीटिंग" → "meeting").
/// Rule-based phonetic romanization: common words come from a lookup table,
/// everything else from letter rules with Hindi schwa deletion.
public enum Hinglish {
    /// Hinglish mode transcribes with language auto-detection. When Whisper
    /// detects something other than English or Hindi (Hindi is often heard
    /// as Urdu), returns the language to transcribe again with.
    public static func retryLanguage(detected: String?, probabilities: [String: Double]) -> String? {
        switch detected?.lowercased() {
        case "en", "english", "hi", "hindi": return nil
        // Languages Hindi speech is commonly mistaken for.
        case "ur", "urdu", "pa", "punjabi", "mr", "marathi", "ne", "nepali", "gu", "gujarati",
             "bn", "bengali", "sa", "sanskrit", "sd", "sindhi":
            return "hi"
        default:
            let en = probabilities["en"] ?? 0
            let hi = (probabilities["hi"] ?? 0) + (probabilities["ur"] ?? 0)
            return hi > en ? "hi" : "en"
        }
    }

    public static func containsDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    public static func romanize(_ text: String) -> String {
        guard containsDevanagari(text) else { return text }
        var out = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            out += romanizeWord(word)
            word = ""
        }
        for ch in text {
            if ch.unicodeScalars.allSatisfy({ (0x0900...0x097F).contains($0.value) && !(0x0964...0x096F).contains($0.value) }) {
                word.append(ch)
            } else {
                flush()
                switch ch {
                case "।", "॥": out += "."
                default:
                    if let v = ch.unicodeScalars.first?.value, (0x0966...0x096F).contains(v) {
                        out += String(v - 0x0966)
                    } else {
                        out.append(ch)
                    }
                }
            }
        }
        flush()
        return out
    }

    static func romanizeWord(_ word: String) -> String {
        if let known = words[word] { return known }
        let roman = letters(word)
        return loanwords[roman] ?? roman
    }

    // MARK: Letter rules

    private struct Unit {
        var consonant: String?
        var vowel: String?        // nil = inherent schwa (decided later)
        var nasal = false
        var afterVowel = false    // independent vowel following another vowel
    }

    static let consonants: [UnicodeScalar: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v", "श": "sh", "ष": "sh", "स": "s", "ह": "h",
        // Precomposed nukta letters.
        "\u{0958}": "q", "\u{0959}": "kh", "\u{095A}": "g", "\u{095B}": "z",
        "\u{095C}": "d", "\u{095D}": "dh", "\u{095E}": "f", "\u{095F}": "y",
    ]
    /// Consonant + combining nukta (U+093C).
    static let nukta: [UnicodeScalar: String] = ["क": "q", "ख": "kh", "ग": "g", "ज": "z", "फ": "f", "ड": "d", "ढ": "dh"]
    static let matras: [UnicodeScalar: String] = [
        "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u", "े": "e", "ै": "ai",
        "ो": "o", "ौ": "au", "ृ": "ri", "ॉ": "o", "ॅ": "e", "ॆ": "e", "ॊ": "o",
    ]
    static let vowels: [UnicodeScalar: String] = [
        "अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo", "ए": "e", "ऐ": "ai",
        "ओ": "o", "औ": "au", "ऋ": "ri", "ऑ": "o", "ऍ": "e",
    ]

    static func letters(_ word: String) -> String {
        var units: [Unit] = []
        var previous: UnicodeScalar?
        for sc in word.unicodeScalars {
            defer { previous = sc }
            if let c = consonants[sc] {
                units.append(Unit(consonant: c))
            } else if sc.value == 0x093C {
                if let p = previous, let c = nukta[p], !units.isEmpty { units[units.count - 1].consonant = c }
            } else if let m = matras[sc], !units.isEmpty {
                units[units.count - 1].vowel = m
            } else if sc.value == 0x094D, !units.isEmpty { // virama
                units[units.count - 1].vowel = ""
            } else if let v = vowels[sc] {
                let afterVowel = !units.isEmpty
                // "भाई" → "bhai", not "bhaee".
                let short = afterVowel ? (["ee": "i", "oo": "u", "aa": "a"][v] ?? v) : v
                units.append(Unit(consonant: nil, vowel: short, afterVowel: afterVowel))
            } else if sc.value == 0x0902 || sc.value == 0x0901, !units.isEmpty { // anusvara, chandrabindu
                units[units.count - 1].nasal = true
            } else if sc.value == 0x0903 { // visarga
                units.append(Unit(consonant: "h", vowel: ""))
            }
        }
        resolveSchwa(&units)
        var s = ""
        for (i, u) in units.enumerated() {
            s += u.consonant ?? ""
            s += u.vowel ?? ""
            if u.nasal {
                let next = i + 1 < units.count ? units[i + 1].consonant ?? "" : ""
                s += ["p", "b", "bh", "m"].contains(next) ? "m" : "n"
            }
        }
        // ज्ञ is pronounced "gy" (ज्ञान → gyaan).
        // Literal (code-unit) search: "ज्ञ" is not a whole grapheme inside "ज्ञा".
        return word.range(of: "ज्ञ", options: .literal) != nil ? s.replacingOccurrences(of: "jn", with: "gy") : s
    }

    /// Hindi drops the inherent "a" at the end of a word and in V C _ C V
    /// position: रखते → rakhte, कमरा → kamra, but समझ → samajh.
    private static func resolveSchwa(_ units: inout [Unit]) {
        guard !units.isEmpty else { return }
        let n = units.count
        if units[n - 1].consonant != nil, units[n - 1].vowel == nil {
            units[n - 1].vowel = n == 1 ? "a" : ""
        }
        var i = n - 2
        while i >= 1 {
            let next = units[i + 1]
            let nextHasVowel = next.consonant != nil && !(next.vowel ?? "a").isEmpty
            if units[i].consonant != nil, units[i].vowel == nil,
               !(units[i - 1].vowel ?? "a").isEmpty, nextHasVowel {
                units[i].vowel = ""
            }
            i -= 1
        }
        for k in units.indices where units[k].consonant != nil && units[k].vowel == nil {
            units[k].vowel = "a"
        }
    }

    // MARK: Tables

    /// Everyday Hindi words, spelled the way they are usually typed.
    static let words: [String: String] = [
        "भाई": "bhai", "नहीं": "nahi", "नही": "nahi", "हैं": "hain", "है": "hai", "में": "mein", "मैं": "main",
        "क्या": "kya", "क्यों": "kyun", "क्यूँ": "kyun", "क्योंकि": "kyunki", "यह": "yeh", "ये": "ye", "वह": "woh",
        "वो": "wo", "हाँ": "haan", "हां": "haan", "ठीक": "theek", "भी": "bhi", "जी": "ji", "और": "aur", "तो": "toh",
        "कि": "ki", "की": "ki", "ही": "hi", "अभी": "abhi", "कभी": "kabhi", "सभी": "sabhi", "सही": "sahi",
        "मुझे": "mujhe", "मुझको": "mujhko", "तुम": "tum", "तुम्हें": "tumhe", "आप": "aap", "हम": "hum", "बहुत": "bahut",
        "अच्छा": "accha", "अच्छी": "acchi", "अच्छे": "acche", "चलो": "chalo", "यार": "yaar", "बात": "baat",
        "लेकिन": "lekin", "पर": "par", "फिर": "phir", "कुछ": "kuch", "सब": "sab", "कैसे": "kaise", "कैसा": "kaisa",
        "कैसी": "kaisi", "ऐसा": "aisa", "ऐसे": "aise", "वैसे": "waise", "एक": "ek", "दो": "do", "कोई": "koi",
        "अपना": "apna", "अपने": "apne", "अपनी": "apni", "हूँ": "hoon", "हूं": "hoon", "हो": "ho", "था": "tha",
        "थी": "thi", "थे": "the", "गया": "gaya", "गई": "gayi", "गए": "gaye", "करना": "karna", "करो": "karo",
        "कर": "kar", "करके": "karke", "दिन": "din", "कल": "kal", "आज": "aaj", "परसों": "parson", "बजे": "baje",
        "साथ": "saath", "लिए": "liye", "लिये": "liye", "जब": "jab", "तब": "tab", "अब": "ab", "यहाँ": "yahan",
        "यहां": "yahan", "वहाँ": "wahan", "वहां": "wahan", "मत": "mat", "ना": "na", "न": "na", "वाला": "wala",
        "वाले": "wale", "वाली": "wali", "मेरा": "mera", "मेरी": "meri", "मेरे": "mere", "तेरा": "tera",
        "तेरी": "teri", "उसका": "uska", "उसकी": "uski", "उसे": "use", "इसे": "ise", "को": "ko", "से": "se",
        "का": "ka", "के": "ke", "पे": "pe", "तक": "tak", "भेज": "bhej", "देना": "dena", "दे": "de", "देखो": "dekho",
        "बोलो": "bolo", "बोला": "bola", "पता": "pata", "चाहिए": "chahiye", "सकता": "sakta", "सकते": "sakte",
        "सकती": "sakti", "रहा": "raha", "रही": "rahi", "रहे": "rahe", "हुआ": "hua", "हुई": "hui", "हुए": "hue",
        "बस": "bas", "ज़्यादा": "zyada", "ज्यादा": "zyada", "थोड़ा": "thoda", "जल्दी": "jaldi", "शाम": "shaam",
        "सुबह": "subah", "रात": "raat", "धन्यवाद": "dhanyavaad", "शुक्रिया": "shukriya", "प्लीज़": "please",
        "प्लीज": "please", "यानी": "yaani", "मतलब": "matlab", "बिल्कुल": "bilkul", "शायद": "shayad", "सच": "sach",
    ]

    /// English words as they come out of romanizing Whisper's Devanagari
    /// spelling (including its misspellings, e.g. "ताइम" → "taim").
    static let loanwords: [String: String] = [
        "miting": "meeting", "mitimg": "meeting", "kol": "call", "kaul": "call", "ophis": "office", "ofis": "office",
        "taim": "time", "taaim": "time", "projekt": "project", "projekta": "project", "imel": "email", "eemel": "email",
        "imela": "email", "maisej": "message", "mesej": "message", "phon": "phone", "fon": "phone", "oke": "okay",
        "okay": "okay", "sori": "sorry", "thainks": "thanks", "thaink": "thank", "yu": "you", "dedlain": "deadline",
        "tim": "team", "klaint": "client", "klain": "client", "riport": "report", "aupdet": "update", "apdet": "update",
        "kod": "code", "diploy": "deploy", "sarvar": "server", "aip": "app", "aiap": "app",
        "vebsait": "website", "link": "link", "dok": "doc", "slaik": "Slack", "vhatsep": "WhatsApp",
        "vhatsaip": "WhatsApp", "gugal": "Google", "laiptop": "laptop", "laptop": "laptop", "bos": "boss",
        "bajat": "budget", "plan": "plan", "plain": "plan", "send": "send", "chek": "check", "phail": "file",
        "deta": "data", "detaa": "data", "test": "test", "rivyu": "review", "phidbaik": "feedback",
        "fidbaik": "feedback", "ishu": "issue", "problam": "problem", "prablam": "problem", "chenj": "change",
        "chainj": "change", "ped": "paid", "pement": "payment", "inavois": "invoice", "invois": "invoice",
        "sheduyal": "schedule", "shedyul": "schedule", "kailendar": "calendar", "jum": "Zoom", "zum": "Zoom",
        "redi": "ready", "kampani": "company", "kampni": "company",
        "manejar": "manager", "maineyjar": "manager", "intarvyu": "interview", "prejenteshan": "presentation",
        "prezenteshan": "presentation", "aipruv": "approve", "apruv": "approve", "kanfarm": "confirm",
        "kainsil": "cancel", "kaisil": "cancel", "risiv": "receive", "risiiv": "receive", "eksel": "Excel",
        "dek": "deck", "slaid": "slide", "slaids": "slides",
    ]
}
