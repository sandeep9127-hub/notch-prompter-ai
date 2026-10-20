import AppKit
import Combine
import SwiftUI

/// A borderless panel that can sit over the menu bar, around the notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class PrompterPanelController {
    let panel: NotchPanel
    private let state: AppState
    private var bag = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Keeps the prompter out of screen sharing and screen recordings.
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: PrompterView().environmentObject(state))

        Publishers.Merge4(
            state.$fontSize.map { _ in () },
            state.$panelWidth.map { _ in () },
            state.$visibleLines.map { _ in () },
            state.$cuesEnabled.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.layout() }
        .store(in: &bag)

        state.$isPrompterVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.setVisible(visible) }
            .store(in: &bag)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    private struct NotchGeometry {
        let screen: NSScreen
        let notchHeight: CGFloat
    }

    private static func notchGeometry() -> NotchGeometry? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else {
            return nil
        }
        let top = screen.safeAreaInsets.top
        return NotchGeometry(screen: screen, notchHeight: top > 0 ? top : NSStatusBar.system.thickness)
    }

    func layout() {
        guard let geometry = Self.notchGeometry() else { return }
        if state.notchHeight != geometry.notchHeight { state.notchHeight = geometry.notchHeight }
        let width = CGFloat(state.panelWidth)
        let height = state.panelHeight
        let frame = geometry.screen.frame
        panel.setFrame(
            NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height),
            display: true
        )
    }

    func setVisible(_ visible: Bool) {
        if visible {
            layout()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}

struct PrompterView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.notchHeight)
            scriptArea
            if state.cuesEnabled { cueArea }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                .fill(Color.black)
        )
        .onHover { state.isHovering = $0 }
    }

    private var scriptArea: some View {
        let lineHeight = state.lineHeight
        return ZStack(alignment: .topLeading) {
            if state.lines.isEmpty {
                Text("Open the script editor from the menu bar icon to add your script.")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .padding(.horizontal, AppState.horizontalPadding)
            } else {
                ScriptLinesView(
                    words: state.words,
                    lines: state.lines,
                    spoken: state.spokenWordIndex,
                    dimSpoken: state.mode == .voice,
                    fontSize: state.fontSize,
                    lineHeight: lineHeight
                )
                .equatable()
                .padding(.horizontal, AppState.horizontalPadding)
                .offset(y: -state.scrollOffset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CGFloat(state.visibleLines) * lineHeight, alignment: .top)
        .clipped()
        .overlay(alignment: .topTrailing) { indicator }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var indicator: some View {
        if state.mode == .voice && state.isPlaying {
            Circle().fill(Color.green).frame(width: 6, height: 6).padding(.trailing, 8)
        } else if state.mode == .timed && (!state.isPlaying || state.isHovering) && !state.lines.isEmpty {
            Image(systemName: "pause.fill").font(.system(size: 8)).foregroundColor(.gray).padding(.trailing, 8)
        }
    }

    private var cueArea: some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).padding(.bottom, 3)
            if state.cues.isEmpty {
                Text(state.cueStatus.isEmpty ? "Listening for the other side…" : state.cueStatus)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(2)
            } else {
                ForEach(Array(state.cues.enumerated()), id: \.offset) { _, cue in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("›")
                        Text(cue).lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.yellow)
                }
            }
        }
        .padding(.horizontal, AppState.horizontalPadding)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AppState.cueAreaHeight, alignment: .top)
    }
}

/// Renders every script line at a fixed height. Kept equatable so the 60 fps scroll
/// offset changes don't rebuild the text.
struct ScriptLinesView: View, Equatable {
    let words: [String]
    let lines: [ScriptLine]
    let spoken: Int
    let dimSpoken: Bool
    let fontSize: Double
    let lineHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                text(for: line)
                    .font(.system(size: CGFloat(fontSize), weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: lineHeight)
            }
        }
    }

    private func joined(_ range: Range<Int>) -> String {
        words[range].joined(separator: " ")
    }

    private func text(for line: ScriptLine) -> Text {
        guard dimSpoken else { return Text(verbatim: joined(line.words)).foregroundColor(.white) }
        let split = min(max(spoken, line.words.lowerBound), line.words.upperBound)
        let done = joined(line.words.lowerBound..<split)
        let rest = joined(split..<line.words.upperBound)
        let separator = (!done.isEmpty && !rest.isEmpty) ? " " : ""
        return Text(verbatim: done + separator).foregroundColor(Color.white.opacity(0.35))
            + Text(verbatim: rest).foregroundColor(.white)
    }
}
