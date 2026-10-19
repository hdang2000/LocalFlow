# Wispr Flow vs LocalFlow: feature comparison

**Reference:** Wispr Flow 1.6.1174 (`com.electron.wispr-flow`), installed in
`/Applications`. **Compared with:** LocalFlow 0.1.0.

**How Wispr Flow was examined:**

- Read the shipped Electron bundle (UI text, shortcut tables) without running
  any of its code.
- Read the user's local shortcut preferences (`config.json` keys only).
- Read Wispr's public documentation.

Not accessed: its servers, private APIs, auth tokens, server-side prompts and
models. Wispr Flow's transcription and cleanup run in its cloud. LocalFlow
uses a local Whisper model plus deterministic rules, so **output is not
equivalent**, only the workflows are comparable.

**Evidence labels:**

- **bundle**: seen in the shipped app.
- **prefs**: seen in the user's settings.
- **docs**: public documentation.
- **inferred**: an inference, not confirmed.

**Test labels:**

- **unit**: `scripts/test.sh`, 41 tests passing.
- **speech**: real audio synthesized with macOS `say`, transcribed by
  whisper-server with outbound network blocked (`sandbox-exec`), then run
  through the pipeline.
- **live**: needs a person at the keyboard and microphone; not yet run unless
  marked.

## 1. Desktop interaction

| Feature | Wispr Flow (observed) | LocalFlow | Test | Known differences |
|---|---|---|---|---|
| Push-to-talk | Hold Fn (prefs `63 → ptt`). A tap shows “Don't tap. Hold down …” (bundle) | Hold Fn (or Right ⌥/⌘/⌃). A press shorter than 0.35 s shows “Hold the push-to-talk key…” | live: pending | — |
| Hands-free | Fn+Space (prefs `49+63 → popo`) | Fn+Space toggles, Fn ends it; presets ⌃⌥Space and ⌥⌘D | live: pending | Wispr also offers a double-tap hint and mouse-button bindings |
| Cancel | Esc (prefs `53 → dismiss`) | Esc, consumed only while recording | live: pending | — |
| Paste / copy last | ⌘⌃V / ⌘⌃C (prefs) | Same | live: pending | — |
| Floating indicator | “Flow bar” with Listening, Cancel, “Finish and paste” (bundle) | Bottom-center pill: level bars, timer, Finish (hands-free), Cancel | live: pending | Visual design differs; Wispr's bar has menus (mic, language, history) |
| Processing indicator | Present (bundle) | Spinner with “Transcribing…” | live: pending | — |
| Auto-insert | Paste into the active app; restores the clipboard by default (inferred from a `disable-clipboard-restore` flag) | Pastes with ⌘V, then restores the previous clipboard if unchanged | live: pending | — |
| No text field | “Select a textbox first…”, with copy (bundle) | Copies, then shows “No text field focused — copied” | live: pending | LocalFlow checks only the focused element's role through Accessibility |
| Failure recovery | “We couldn't hear you”, “Is your microphone muted?”; retry from history within 14 days (bundle) | Same silence messages; the failed audio is kept on disk with a Retry button in the pill and menu | speech: engine verified; retry: live pending | LocalFlow keeps only the last failed recording |
| Max length | 20 min, with a 1-minute warning (bundle) | 20 min; the timer turns orange in the last minute | live: pending | — |
| Command / Instruct / Polish | Cloud LLM features (bundle) | **Not implemented** | — | Out of scope: these need an LLM |

## 2. Personalization

| Feature | Wispr Flow | LocalFlow | Test | Known differences |
|---|---|---|---|---|
| Dictionary | Words plus “misspelling → correct” rules; auto-learns from your edits (bundle) | Terms plus “misheard as” corrections. Terms also bias Whisper through its prompt. Stored in `~/Library/Application Support/LocalFlow/settings.json` | unit ✓; speech ✓ (“whisper flow” → “Wispr Flow”, “Himanshu” kept) | No auto-learning: it would require reading text after insertion |
| Snippets | Trigger plus (rich) expansion (bundle) | Trigger plus plain-text expansion, inserted verbatim; longest trigger wins | unit ✓; speech ✓ | Plain text only |
| Styles | Formal, Casual, Very casual, Excited per category (Personal, Work, Email, Other); English only (bundle) | The same four, plus Professional email and Technical, per category (Personal, Work, Email, Coding, Other) | unit ✓; speech ✓ (very casual, excited, email) | Wispr's styles are LLM rewrites; LocalFlow's are rule-based (casing, punctuation, layout, slang expansion) |
| Backtracking | Not named in the bundle; likely part of LLM cleanup (inferred) | Rules for “no wait”, “I meant”, “actually”, “scratch that”, “never mind”, and so on | unit ✓; speech ✓ (“2pm, no wait, 3pm on Thursday” → “3pm on Thursday”) | Heuristic: unusual phrasings may not be caught |
| Fillers | Removed (bundle) | um/uh/er, comma-bound “like/you know/basically”, stutters | unit ✓; speech ✓ | — |
| Lists | Auto-formatted (bundle) | “one … two … three”, “first, … second, …”, and Whisper's “1. … 2. …” become numbered lines | unit ✓; speech ✓ | — |
| Spoken punctuation | Yes (docs) | comma, period, question mark, new line, new paragraph, quotes, parentheses | unit ✓; speech ✓ | — |
| Paragraphs | “Auto cleanup” levels (bundle) | Breaks long prose at transition words, or every 4 sentences | unit ✓ | No clarity or concision rewriting |

## 3. Developer-aware dictation

| Feature | Wispr Flow | LocalFlow | Test | Known differences |
|---|---|---|---|---|
| Tech vocabulary | “Understands dev jargon” (bundle) | More than 80 terms with casing and common mishearings (JSON/“jason”, kubectl, PostgreSQL…) | unit ✓; speech ✓ (“type script” → TypeScript) | — |
| Files / paths / CLI | File tagging in Cursor and Windsurf (bundle) | “slash”, “dot”, “dash”, “dash dash”, “underscore” → symbols; rejoins split extensions like “index. ts” | unit ✓; speech ✓ (`index.ts`, `--save`) | No IDE file tagging |
| camelCase / snake_case / acronyms | Variable recognition (bundle) | camel, pascal, snake, kebab, constant case, all caps; fixes Whisper's glued `camelCaseX` | unit ✓; speech ✓ (`getUserProfile`) | — |
| Context | “Context awareness” reads text from the current app (bundle) | Optional and **off by default**. Reads only the frontmost app's bundle ID to choose a style or developer mode. Never reads document contents | unit ✓ | Less context than Wispr, by design |
| No execution | — | Only ⌘V is ever sent, never Return | unit ✓ (no trailing newline) | Wispr has an experimental “Press Enter” voice command; LocalFlow deliberately does not |

## 4. Processing model

| | Wispr Flow | LocalFlow |
|---|---|---|
| Transcription | Cloud; needs internet (docs) | whisper.cpp `large-v3-turbo`, on device; verified with outbound network blocked |
| Cleanup / formatting | Cloud LLM | Deterministic local rules |
| Languages | 100+ with auto-detect | Whisper's multilingual model (English, auto-detect and common languages in Settings). Cleanup rules are English-only |
| Data | Cloud account and sync | Local JSON files only; history can be turned off |

## Performance

Measured on this Mac (Apple Silicon), speech tests, warm runs:

- Model load: about 1.3 s.
- Transcription of a 4–6 s clip: about 1.4 s.

- Memory (resident, idle after loading): LocalFlow about 49 MB, whisper-server
  about 1.8 GB.

Not yet measured: cold first load after reboot, and long recordings.

## Pending live verification

These need a person at the keyboard and microphone:

- Fn hold and release
- Fn+Space hands-free
- Esc cancel
- ⌃⌘V / ⌃⌘C
- Indicator rendering
- Paste into real apps (Notes, Slack, a browser, Terminal)
- Clipboard restore
- Secure-input fallback
- Retry after a failure

Ask Claude to run a guided live session to complete these.
