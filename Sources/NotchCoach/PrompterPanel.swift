import AppKit
import Combine
import SwiftUI

/// A borderless panel that can sit over the menu bar, around the notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that takes clicks without first activating the app, and tracks hover even
/// while another app is in front (SwiftUI's onHover stops firing when the app is inactive).
final class PrompterHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["prompter"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["prompter": true]
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
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
        panel.acceptsMouseMovedEvents = true
        // Keeps the prompter out of screen sharing and screen recordings.
        panel.sharingType = .none

        let hosting = PrompterHostingView(rootView: AnyView(PrompterView().environmentObject(state)))
        hosting.onHoverChange = { [weak state] hovering in
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.15)) { state?.isHovering = hovering }
            }
        }
        panel.contentView = hosting

        let layoutTriggers: [AnyPublisher<Void, Never>] = [
            state.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            state.$panelWidth.map { _ in () }.eraseToAnyPublisher(),
            state.$visibleLines.map { _ in () }.eraseToAnyPublisher(),
            state.$cuesEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$alwaysShowControls.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(layoutTriggers)
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
            if state.alwaysShowControls {
                PrompterControlBar()
            }
            if state.cuesEnabled { cueArea }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                .fill(Color.black)
        )
    }

    private var scriptArea: some View {
        let lineHeight = state.lineHeight
        return ZStack(alignment: .topLeading) {
            if state.lines.isEmpty {
                Text("Your script is empty. Click the gear to add one.")
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
        .overlay(alignment: .bottom) {
            // With the bar hidden, it slides in over the text while the pointer is on the prompter.
            if !state.alwaysShowControls && state.isHovering {
                PrompterControlBar()
                    .background(Color.black.opacity(0.92))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) { indicators }
        .padding(.top, 6)
    }

    private var indicators: some View {
        HStack(spacing: 6) {
            if state.micActive {
                Image(systemName: "mic.fill").foregroundColor(.green).help("Listening to your microphone")
            }
            if state.cuesEnabled {
                Image(systemName: "waveform").foregroundColor(.orange).help("Listening to call audio for cues")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .padding(.trailing, 10)
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

/// The on-screen controls in the notch: everything the keyboard shortcuts do, plus a hard stop.
struct PrompterControlBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 4) {
            ProgressBar(value: state.progress)
            HStack(spacing: 2) {
                PanelButton(icon: "backward.fill", help: "Back one line  ⌃⌥↑") { state.nudge(lines: -1) }
                PanelButton(
                    icon: state.isPlaying ? "pause.fill" : (state.mode == .voice ? "mic.fill" : "play.fill"),
                    help: playHelp,
                    tint: state.isPlaying ? .white : .green,
                    size: 13
                ) { state.togglePlay() }
                PanelButton(icon: "forward.fill", help: "Forward one line  ⌃⌥↓") { state.nudge(lines: 1) }

                divider

                if state.mode == .timed {
                    PanelButton(icon: "minus", help: "Slower  ⌃⌥−") { state.changeSpeed(by: -5) }
                    Text("\(Int(state.speed))")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(.gray)
                        .frame(width: 22)
                        .help("Scroll speed")
                    PanelButton(icon: "plus", help: "Faster  ⌃⌥=") { state.changeSpeed(by: 5) }
                } else {
                    Text("Voice")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: 70)
                }

                divider

                PanelToggle(
                    icon: "waveform.and.mic",
                    isOn: state.mode == .voice,
                    help: "Follow my voice on / off  ⌃⌥V"
                ) { state.setMode(state.mode == .voice ? .timed : .voice) }
                PanelToggle(
                    icon: "text.bubble",
                    isOn: state.cuesEnabled,
                    help: "Live call cues on / off  ⌃⌥C"
                ) { state.toggleCues() }

                Spacer(minLength: 4)

                PanelButton(
                    icon: "stop.fill",
                    help: "Stop everything: scrolling, microphone, call audio and AI  ⌃⌥Esc",
                    tint: .red,
                    size: 13
                ) { state.hardStop() }

                divider

                PanelButton(icon: "eye.slash", help: "Hide prompter  ⌃⌥H") { state.isPrompterVisible = false }
                PanelButton(icon: "gearshape", help: "Script & settings") { state.onOpenEditor?() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: AppState.controlBarHeight)
    }

    private var playHelp: String {
        if state.mode == .voice {
            return state.isPlaying ? "Stop listening  ⌃⌥Space" : "Start listening  ⌃⌥Space"
        }
        return state.isPlaying ? "Pause  ⌃⌥Space" : "Play  ⌃⌥Space"
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 3)
    }
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.white.opacity(0.55))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 2)
        .help("Position in script")
    }
}

private struct PanelButton: View {
    let icon: String
    let help: String
    var tint: Color = .white
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.16 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct PanelToggle: View {
    let icon: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isOn ? .black : .white.opacity(0.85))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.yellow : Color.white.opacity(0.10))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "On" : "Off")
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
