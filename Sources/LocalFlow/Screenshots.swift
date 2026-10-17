import AppKit
import LocalFlowCore
import SwiftUI

/// Renders the real UI views with sample data to PNGs for the README:
///   LocalFlow --render-screenshots docs/screenshots
/// Uses an in-memory demo controller; never touches the user's data.
enum Screenshots {
    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = AppController(demoSettings: demoSettings, demoHistory: demoHistory)
        let store = AppViewModel(controller: controller)

        // The floating pill in each state.
        let pill = IndicatorModel()
        pill.levels = [0.15, 0.3, 0.55, 0.8, 0.6, 0.9, 0.7, 0.45, 0.85, 0.5, 0.3, 0.6, 0.35, 0.2]
        pill.startedAt = Date().addingTimeInterval(-7)
        let states: [(String, IndicatorModel.Phase)] = [
            ("pill-push-to-talk", .listening(handsFree: false)),
            ("pill-hands-free", .listening(handsFree: true)),
            ("pill-transcribing", .processing),
            ("pill-copied", .notice("No text field focused — copied. Click a text box and press ⌘V.", isError: false, canRetry: false)),
            ("pill-retry", .notice("Transcription failed — your audio is saved.", isError: true, canRetry: true)),
        ]
        for (name, phase) in states {
            pill.phase = phase
            try save(PillShot(model: pill), size: CGSize(width: 520, height: 96), to: dir.appendingPathComponent(name + ".png"))
        }

        try save(HeroShot(), size: CGSize(width: 900, height: 420), to: dir.appendingPathComponent("hero.png"))
        try save(MenuShot(), size: CGSize(width: 360, height: 440), to: dir.appendingPathComponent("menu-bar.png"))

        let pages: [(String, Page)] = [
            ("window-home", .home), ("window-history", .history), ("window-dictionary", .dictionary),
            ("window-snippets", .snippets), ("window-styles", .styles), ("window-try-it", .tryIt),
            ("window-settings", .settings),
        ]
        for (name, page) in pages {
            store.section = page
            try save(MainView(store: store), size: CGSize(width: 980, height: 640),
                     to: dir.appendingPathComponent(name + ".png"), window: true)
        }
    }

    private static func save<V: View>(_ view: V, size: CGSize, to url: URL, window: Bool = false) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: window ? [.titled, .fullSizeContentView] : [.borderless],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.orderFrontRegardless()
        // Let SwiftUI lay out and render.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        w.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }

    // MARK: Sample data

    static var demoSettings: LocalFlowCore.Settings {
        var s = LocalFlowCore.Settings()
        s.dictionary = [
            DictionaryEntry(term: "Priya", corrections: ["Pria", "Preya"]),
            DictionaryEntry(term: "Kubernetes", corrections: ["cooper netties"]),
            DictionaryEntry(term: "Acme Cloud", corrections: ["acne cloud"]),
            DictionaryEntry(term: "OAuth"),
        ]
        s.snippets = [
            Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/me/30min"),
            Snippet(trigger: "my address", expansion: "221B Baker Street, London"),
        ]
        s.useActiveAppForStyle = true
        return s
    }

    static var demoHistory: [HistoryItem] {
        let now = Date()
        return [
            HistoryItem(date: now.addingTimeInterval(-120), raw: "", text: "Let's meet at 6pm on Thursday. I'll bring the slides."),
            HistoryItem(date: now.addingTimeInterval(-900), raw: "", text: "Kal ki meeting ka time change kar do, client ko email bhej dena."),
            HistoryItem(date: now.addingTimeInterval(-3600), raw: "", text: "Rename the function to getUserProfile and update src/app/index.ts."),
            HistoryItem(date: now.addingTimeInterval(-7200), raw: "", text: "Here are my priorities:\n1. Fix the login bug\n2. Update the docs\n3. Deploy to staging"),
            HistoryItem(date: now.addingTimeInterval(-86_000), raw: "", text: "Hi Sam,\n\nThanks for the quick turnaround on the contract.\n\nBest regards,\nAlex"),
        ]
    }
}

/// A pill on a soft desktop-like background.
private struct PillShot: View {
    @ObservedObject var model: IndicatorModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.93), Color(white: 0.86)], startPoint: .top, endPoint: .bottom)
            IndicatorView(model: model, cancel: {}, finish: {}, retry: {}, dismiss: {}, start: {})
                .frame(width: 480, height: 56)
        }
    }
}

/// Illustration: dictating into a chat app.
private struct HeroShot: View {
    let pill: IndicatorModel = {
        let m = IndicatorModel()
        m.phase = .listening(handsFree: false)
        m.levels = [0.2, 0.45, 0.7, 0.9, 0.6, 0.8, 0.5, 0.75, 0.95, 0.55, 0.35, 0.6, 0.4, 0.25]
        m.startedAt = Date().addingTimeInterval(-4)
        return m
    }()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.62), Color(red: 0.10, green: 0.09, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 28, height: 28)
                        Text("Sam").font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }
                    HStack {
                        Text("are we still on for tomorrow?")
                            .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.92)))
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Text("Yes! Let's meet at 6pm on Thursday. I'll bring the slides.")
                            .foregroundStyle(.white)
                            .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Color.blue))
                    }
                    HStack(spacing: 6) {
                        Text("Hold").foregroundStyle(.secondary)
                        Text("fn").font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary))
                        Text("· speak · release — the text is typed for you").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                .font(.system(size: 14))
                .padding(20)
                .frame(width: 560)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                IndicatorView(model: pill, cancel: {}, finish: {}, retry: {}, dismiss: {}, start: {})
                    .frame(width: 480, height: 56)
            }
        }
    }
}

/// The menu-bar menu, drawn to match its real items.
private struct MenuShot: View {
    private let rows: [(String, Bool)] = [
        ("Hold Fn (🌐) to dictate · Fn (🌐)+Space hands-free", false),
        ("Speech engine: ready (offline)", false),
        ("—", false),
        ("Start Hands-free Dictation", true),
        ("Open LocalFlow", true),
        ("Paste Last Transcript", true),
        ("Copy Last Transcript", true),
        ("Recent  ›", true),
        ("—", false),
        ("Default Style  ›", true),
        ("Developer Mode", true),
        ("Settings…                ⌘,", true),
        ("—", false),
        ("Quit LocalFlow           ⌘Q", true),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(white: 0.85), Color(white: 0.78)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.12)))
                }
                .padding(.horizontal, 12).padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        if row.0 == "—" {
                            Divider().padding(.vertical, 4)
                        } else {
                            Text(row.0)
                                .font(.system(size: 13))
                                .foregroundStyle(row.1 ? Color.primary : Color.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(width: 320)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.97)))
                .shadow(radius: 8, y: 3)
                .padding(.trailing, 12)
            }
        }
    }
}
