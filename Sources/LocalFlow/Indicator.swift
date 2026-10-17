import AppKit
import SwiftUI

final class IndicatorModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        /// The small resting bar shown when "Show idle bar" is on.
        case idle
        case listening(handsFree: Bool)
        case processing
        case notice(String, isError: Bool, canRetry: Bool)
    }
    @Published var phase: Phase = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 14)
    @Published var startedAt = Date()
    @Published var limitWarning = false

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// A small floating pill near the bottom of the screen. It never takes focus,
/// so the target app keeps its cursor while you dictate.
final class IndicatorPanel {
    let model = IndicatorModel()
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onStart: (() -> Void)?
    var idleBarEnabled = false {
        didSet { if model.phase == .hidden || model.phase == .idle { show(.hidden) } }
    }

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = IndicatorView(model: model,
                                 cancel: { [weak self] in self?.onCancel?() },
                                 finish: { [weak self] in self?.onFinish?() },
                                 retry: { [weak self] in self?.onRetry?() },
                                 dismiss: { [weak self] in self?.onDismiss?() },
                                 start: { [weak self] in self?.onStart?() })
        p.contentView = NSHostingView(rootView: view)
        return p
    }()
    private var hideWork: DispatchWorkItem?

    func show(_ requested: IndicatorModel.Phase, autoHideAfter seconds: Double? = nil) {
        hideWork?.cancel()
        let phase = requested == .hidden && idleBarEnabled ? .idle : requested
        if case .listening = phase, model.phase != phase {
            model.startedAt = Date()
            model.levels = Array(repeating: 0, count: model.levels.count)
            model.limitWarning = false
        }
        model.phase = phase
        guard phase != .hidden else { panel.orderOut(nil); return }
        position()
        panel.orderFrontRegardless()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}

struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel
    let cancel: () -> Void
    let finish: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void
    let start: () -> Void

    var body: some View {
        if model.phase == .idle {
            idleBar
        } else {
            pill
        }
    }

    /// A slim resting bar; click it to start hands-free dictation.
    private var idleBar: some View {
        Button(action: start) {
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.75)).frame(width: 2, height: [4, 7, 10, 6, 9, 5, 3][i])
                }
            }
            .frame(width: 56, height: 16)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .overlay(Capsule().stroke(Color.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .help("Click to dictate hands-free, or hold your push-to-talk key")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        .foregroundStyle(.white)
        .font(.system(size: 12, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden, .idle:
            EmptyView()
        case .listening(let handsFree):
            Circle().fill(Color.red).frame(width: 8, height: 8)
            HStack(spacing: 2) {
                ForEach(Array(model.levels.enumerated()), id: \.offset) { _, l in
                    Capsule().fill(Color.white).frame(width: 3, height: 4 + CGFloat(l) * 18)
                }
            }
            .frame(height: 22)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(ctx.date)).monospacedDigit()
                    .foregroundStyle(model.limitWarning ? Color.orange : Color.white.opacity(0.7))
            }
            if handsFree {
                Button("Finish", action: finish).buttonStyle(.borderless).foregroundStyle(.white)
            }
            Button(action: cancel) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.7)).help("Cancel (Esc)")
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
            Text("Transcribing…")
        case .notice(let text, let isError, let canRetry):
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button("Retry", action: retry).buttonStyle(.borderless).foregroundStyle(.white)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(model.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
