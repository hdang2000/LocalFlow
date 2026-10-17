import Testing
@testable import LocalFlowCore

private func run(_ s: String, _ o: PipelineOptions = PipelineOptions()) -> String {
    TextPipeline.process(s, options: o)
}

@Suite struct CleanupTests {
    @Test func stripsWhisperArtifacts() {
        #expect(run("[BLANK_AUDIO]") == "")
        #expect(run(" (music) Hello there.") == "Hello there.")
    }
}

@Suite struct FillerTests {
    @Test func removesHesitations() {
        #expect(run("Um, I think, uh, we should ship it.") == "I think, we should ship it.")
        #expect(run("So, like, the build is, you know, broken.") == "The build is broken.")
    }
    @Test func keepsMeaningfulLike() {
        #expect(run("I like this design.") == "I like this design.")
    }
    @Test func removesStutters() {
        #expect(run("The the deploy failed.") == "The deploy failed.")
    }
}

@Suite struct BacktrackingTests {
    @Test func replacesTrailingValue() {
        #expect(run("Let's meet at 2pm, actually 3pm.") == "Let's meet at 3pm.")
    }
    @Test func restartsFromRepeatedWord() {
        #expect(run("Send it to John, no wait, to Sarah.") == "Send it to Sarah.")
    }
    @Test func iMeant() {
        #expect(run("The meeting is on Tuesday, I meant Wednesday.") == "The meeting is on Wednesday.")
    }
    @Test func scratchThat() {
        #expect(run("This is wrong. Scratch that. This is right.") == "This is right.")
    }
    @Test func numericCorrectionKeepsContext() {
        #expect(run("Let's meet at 2pm, no wait, 3pm on Thursday.") == "Let's meet at 3pm on Thursday.")
    }
    @Test func restartWithNewSubject() {
        #expect(run("I'll call him, actually we'll email him instead.") == "We'll email him instead.")
    }
    // Real phrasings from live dictation (Whisper output as heard).
    @Test func spokenValueCorrections() {
        #expect(run("I have a meeting at 2pm no no 6pm but it moved.") == "I have a meeting at 6pm but it moved.")
        #expect(run("I want to fix a meeting with Priya tomorrow at 3pm. No, no, not 3pm. At 6pm.")
                == "I want to fix a meeting with Priya tomorrow at 6pm.")
        #expect(run("Let's book a call at 2pm tomorrow. No, let it be, not 2pm, make it 6pm.")
                == "Let's book a call at 6pm tomorrow.")
        #expect(run("See you Monday, actually Tuesday.") == "See you Tuesday.")
    }
    @Test func relativeDayCorrections() {
        #expect(run("I want to connect with Priya tomorrow. Not tomorrow, make it day after tomorrow. And the time would be 2 p.m. No, no, not 2 p.m. Make it 6 p.m.")
                == "I want to connect with Priya day after tomorrow. And the time would be 6 p.m.")
        #expect(run("I want to connect with Priya tomorrow, no not tomorrow, day after tomorrow at 3pm, oh not 3pm, make it 4pm.")
                == "I want to connect with Priya day after tomorrow at 4pm.")
        #expect(run("Let's do Friday, no wait, next Monday.") == "Let's do next Monday.")
    }
    @Test func longTailAfterNoIsLeftAlone() {
        let s = "I asked him, no one else was there and the room was completely empty that night."
        #expect(run(s) == s)
    }
    @Test func unrelatedNoIsKept() {
        #expect(run("I said no to the 2pm slot and booked 6pm.") == "I said no to the 2pm slot and booked 6pm.")
        #expect(run("No, I can't make it at 3pm.") == "No, I can't make it at 3pm.")
    }
    @Test func trailingWordCorrection() {
        #expect(run("Buy apples, sorry, pears and milk.") == "Buy pears and milk.")
    }
    @Test func correctionAsNewSentence() {
        #expect(run("Let's meet at 2pm. Actually 3pm.") == "Let's meet at 3pm.")
        #expect(run("Book it for Monday. No wait, Tuesday.") == "Book it for Tuesday.")
    }
    @Test func sentenceStartingWithActuallyIsKept() {
        #expect(run("That works. Actually, I think the plan is great.") == "That works. Actually, I think the plan is great.")
    }
    @Test func ordinaryActuallyIsKept() {
        #expect(run("I actually like the new version.") == "I actually like the new version.")
    }
    @Test func canBeDisabled() {
        var o = PipelineOptions(); o.backtracking = false
        #expect(run("Meet at 2pm, actually 3pm.", o) == "Meet at 2pm, actually 3pm.")
    }
}

@Suite struct PunctuationTests {
    @Test func spokenMarks() {
        #expect(run("hello comma how are you question mark") == "Hello, how are you?")
        #expect(run("first line new line second line") == "First line\nSecond line.")
        #expect(run("intro new paragraph body text") == "Intro\n\nBody text.")
    }
    @Test func periodAsNounIsKept() {
        #expect(run("It took a period of time.") == "It took a period of time.")
    }
}

@Suite struct ListTests {
    @Test func spokenNumberedList() {
        #expect(run("My groceries are one milk two eggs three bread")
                == "My groceries are:\n1. Milk\n2. Eggs\n3. Bread")
    }
    @Test func ordinalWords() {
        #expect(run("Steps: first, install it. Second, run it. Third, test it.")
                == "Steps:\n1. Install it\n2. Run it\n3. Test it")
    }
    @Test func singleNumberIsNotAList() {
        #expect(run("I have two dogs.") == "I have two dogs.")
    }
}

@Suite struct DictionaryTests {
    @Test func correctionsAndCasing() {
        let o = PipelineOptions(dictionary: [
            DictionaryEntry(term: "Anjali", corrections: ["and jolly"]),
            DictionaryEntry(term: "REA"),
        ])
        #expect(run("ask and jolly about rea", o) == "Ask Anjali about REA.")
    }
    @Test func builtInBrandCasing() {
        #expect(run("push it to github") == "Push it to GitHub.")
    }
    @Test func veryCasualKeepsTermCase() {
        let o = PipelineOptions(style: .veryCasual, dictionary: [DictionaryEntry(term: "GitHub")])
        #expect(run("Check GitHub. I pushed it.", o) == "check GitHub i pushed it")
    }
}

@Suite struct SnippetTests {
    @Test func expandsTriggerVerbatim() {
        let o = PipelineOptions(snippets: [Snippet(trigger: "my calendar link", expansion: "https://cal.com/me")])
        #expect(run("Here is my calendar link.", o) == "Here is https://cal.com/me")
    }
    @Test func longestTriggerWins() {
        let o = PipelineOptions(snippets: [
            Snippet(trigger: "my address", expansion: "A"),
            Snippet(trigger: "my work address", expansion: "B"),
        ])
        #expect(run("my work address", o) == "B")
    }
}

@Suite struct StyleTests {
    @Test func casualDropsFinalPeriod() {
        #expect(run("sounds good see you then", PipelineOptions(style: .casual)) == "Sounds good see you then")
    }
    @Test func veryCasual() {
        #expect(run("Sounds good. I'll be there.", PipelineOptions(style: .veryCasual)) == "sounds good i'll be there")
    }
    @Test func excited() {
        #expect(run("Thanks for the help. See you soon.", PipelineOptions(style: .excited))
                == "Thanks for the help! See you soon!")
    }
    @Test func emailLayout() {
        let out = run("hi Sarah, I wanted to follow up on the contract. best regards Alex",
                      PipelineOptions(style: .professionalEmail))
        #expect(out == "Hi Sarah,\n\nI wanted to follow up on the contract.\n\nBest regards,\nAlex")
    }
    @Test func emailFromWhisperOutput() {
        let out = run("Hi Sarah, I wanted to follow up on the contract and confirm the timeline. Best regards Alex.",
                      PipelineOptions(style: .professionalEmail))
        #expect(out == "Hi Sarah,\n\nI wanted to follow up on the contract and confirm the timeline.\n\nBest regards,\nAlex")
    }
    @Test func formalExpandsSlang() {
        #expect(run("we're gonna ship it") == "We're going to ship it.")
    }
}

@Suite struct DeveloperTests {
    let dev = PipelineOptions(developerMode: true)

    @Test func caseCommands() {
        #expect(run("rename it to camel case user account id", dev) == "Rename it to userAccountId")  // identifiers get no trailing period
        #expect(run("snake case max retry count", dev) == "max_retry_count")
        #expect(run("constant case api base url", dev) == "API_BASE_URL")
    }
    @Test func whisperGluedCaseCommand() {
        #expect(run("Rename it to camelCaseGetUserProfile.", dev) == "Rename it to getUserProfile.")
    }
    @Test func filesAndPaths() {
        #expect(run("open src slash app slash index dot ts", dev) == "Open src/app/index.ts.")
    }
    @Test func cliFlags() {
        #expect(run("run git commit dash m", dev) == "Run git commit -m.")
        #expect(run("npm install dash dash save dev", dev) == "npm install --save dev.")
    }
    @Test func techVocabulary() {
        #expect(run("parse the jason response from the api", dev) == "Parse the JSON response from the API.")
        #expect(run("use type script and post gress", dev) == "Use TypeScript and Postgres.")
    }
    @Test func neverAddsExecutionKeys() {
        // Dictation is text only: no trailing newline that a terminal would run.
        #expect(!run("sudo rm dash rf slash tmp slash cache", dev).hasSuffix("\n"))
    }
    @Test func recognitionPromptIncludesTerms() {
        let o = PipelineOptions(developerMode: true, dictionary: [DictionaryEntry(term: "LocalFlow")])
        #expect(TextPipeline.recognitionPrompt(options: o).contains("LocalFlow"))
        #expect(TextPipeline.recognitionPrompt(options: PipelineOptions()) == "")
    }
}

@Suite struct ParagraphTests {
    @Test func breaksAtTransitions() {
        let s = "The release is ready. Tests pass. Docs are updated. Also, the team needs a demo. We can do Friday."
        #expect(run(s) == "The release is ready. Tests pass. Docs are updated.\n\nAlso, the team needs a demo. We can do Friday.")
    }
}

@Suite struct HinglishTests {
    @Test func romanizesEverydayHindi() {
        #expect(Hinglish.romanize("भाई, मुझे कुछ समझ नहीं आ रहा, कल मीटिंग 6 बजे रखते हैं.")
                == "bhai, mujhe kuch samajh nahi aa raha, kal meeting 6 baje rakhte hain.")
    }
    @Test func restoresEnglishWordsWhisperSpelledInDevanagari() {
        #expect(Hinglish.romanize("कल की मीटिंग का ताइम चेंज कर दो, क्लाइन को इमेल भेज देना.")
                == "kal ki meeting ka time change kar do, client ko email bhej dena.")
    }
    @Test func schwaDeletion() {
        #expect(Hinglish.romanize("कमरा") == "kamra")
        #expect(Hinglish.romanize("मिलना") == "milna")
        #expect(Hinglish.romanize("समझ") == "samajh")
        #expect(Hinglish.romanize("घर") == "ghar")
    }
    @Test func nuktaAndClusters() {
        #expect(Hinglish.romanize("ज़रूर") == "zarur")
        #expect(Hinglish.romanize("ज्ञान") == "gyan")
        #expect(Hinglish.romanize("प्यार") == "pyar")
    }
    @Test func leavesEnglishAlone() {
        #expect(Hinglish.romanize("Send the report today.") == "Send the report today.")
    }
    @Test func fullPipelineCapitalizes() {
        let raw = Hinglish.romanize("भाई, मुझे कुछ समझ नहीं आ रहा।")
        #expect(TextPipeline.process(raw, options: PipelineOptions()) == "Bhai, mujhe kuch samajh nahi aa raha.")
    }
    @Test func retryOnlyForOtherLanguages() {
        #expect(Hinglish.retryLanguage(detected: "hindi", probabilities: [:]) == nil)
        #expect(Hinglish.retryLanguage(detected: "english", probabilities: [:]) == nil)
        #expect(Hinglish.retryLanguage(detected: "urdu", probabilities: ["ur": 0.6, "hi": 0.3, "en": 0.05]) == "hi")
        #expect(Hinglish.retryLanguage(detected: "welsh", probabilities: ["cy": 0.5, "en": 0.4, "hi": 0.01]) == "en")
        // Without probabilities (the fast server mode).
        #expect(Hinglish.retryLanguage(detected: "urdu", probabilities: [:]) == "hi")
        #expect(Hinglish.retryLanguage(detected: "welsh", probabilities: [:]) == "en")
    }
}

@Suite struct SettingsTests {
    @Test func styleNeedsPermission() {
        var s = Settings()
        #expect(s.style(forBundleID: "com.apple.mail") == .formal)
        s.useActiveAppForStyle = true
        #expect(s.style(forBundleID: "com.apple.mail") == .professionalEmail)
        #expect(s.developerModeActive(forBundleID: "com.microsoft.VSCode"))
    }
    @Test func lenientDecoding() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"language":"de"}"#.utf8))
        #expect(s.language == "de")
        #expect(s.shortcuts.pushToTalk == .fn)
        #expect(s.idleUnloadMinutes == 15)
    }
}

import Foundation
