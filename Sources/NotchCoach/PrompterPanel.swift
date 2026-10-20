import AppKit
import Combine
import SwiftUI

/// A borderless panel that can sit over the menu bar, around the notch, or float.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that takes clicks without first activating the app, tracks hover even while
/// another app is in front, and lets the floating prompter be dragged by its top handle.
final class PrompterHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    var canDrag: (() -> Bool)?
    var handleHeight: CGFloat = 22

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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inHandle = isFlipped ? point.y <= handleHeight : point.y >= bounds.height - handleHeight
        if inHandle, canDrag?() == true {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class PrompterPanelController {
    let panel: NotchPanel
    private let state: AppState
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(state: AppState) {
        self.state = state
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
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
        hosting.canDrag = { [weak state] in
            MainActor.assumeIsolated { state?.placement == .floating }
        }
        hosting.handleHeight = AppState.handleHeight
        panel.contentView = hosting

        let layoutTriggers: [AnyPublisher<Void, Never>] = [
            state.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            state.$panelWidth.map { _ in () }.eraseToAnyPublisher(),
            state.$visibleLines.map { _ in () }.eraseToAnyPublisher(),
            state.$cuesEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$alwaysShowControls.map { _ in () }.eraseToAnyPublisher(),
            state.$placement.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(layoutTriggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.layout() }
            .store(in: &bag)

        state.$isPrompterVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.setVisible(visible) }
            .store(in: &bag)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberFloatingPosition() }
        })
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// A screen other than the built-in one, for the "Other display" placement.
    private var otherScreen: NSScreen? {
        let builtIn = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        return NSScreen.screens.first(where: { $0 != builtIn }) ?? NSScreen.main
    }

    func layout() {
        guard let screen = notchScreen else { return }
        let top = screen.safeAreaInsets.top
        let notchHeight = top > 0 ? top : NSStatusBar.system.thickness
        if state.notchHeight != notchHeight { state.notchHeight = notchHeight }

        let width = CGFloat(state.panelWidth)
        let height = state.panelHeight
        switch state.placement {
        case .notch:
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            let frame = screen.frame
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        case .floating:
            panel.level = .floating
            let visible = (NSScreen.main ?? screen).visibleFrame
            var origin = NSPoint(x: visible.midX - width / 2, y: visible.maxY - height - 12)
            if let saved = UserDefaults.standard.string(forKey: "floatingOrigin") {
                let point = NSPointFromString(saved)
                if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: point.x + 20, y: point.y + height - 20)) }) {
                    origin = point
                }
            }
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        case .display:
            panel.level = .floating
            let visible = (otherScreen ?? screen).visibleFrame
            panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 8, width: width, height: height), display: true)
        }
    }

    private func rememberFloatingPosition() {
        guard state.placement == .floating else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "floatingOrigin")
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

/// Colours for the prompter. The notch prompter is always dark; floating ones can be light.
struct PrompterPalette {
    let background: Color
    let text: Color
    let dimText: Color
    let control: Color
    let controlFill: Color
    let separator: Color
    let marker: Color
    let primaryFill: Color
    let primaryText: Color
    let stopFill: Color
    let stopText: Color
    let cardFill: Color

    static let dark = PrompterPalette(
        background: .black, text: .white, dimText: Color.white.opacity(0.32),
        control: Color.white.opacity(0.86), controlFill: Color.white.opacity(0.08),
        separator: Color.white.opacity(0.14), marker: Color(red: 1, green: 0.84, blue: 0.04),
        primaryFill: .white, primaryText: .black,
        stopFill: Color(red: 1, green: 0.27, blue: 0.23).opacity(0.16), stopText: Color(red: 1, green: 0.27, blue: 0.23),
        cardFill: Color(white: 0.11)
    )

    static let light = PrompterPalette(
        background: Color.white.opacity(0.96), text: Color(white: 0.11), dimText: Color(white: 0.11).opacity(0.38),
        control: Color(white: 0.23), controlFill: Color.black.opacity(0.05),
        separator: Color.black.opacity(0.12), marker: Color(red: 0.88, green: 0.66, blue: 0),
        primaryFill: Color(white: 0.11), primaryText: .white,
        stopFill: Color(red: 1, green: 0.9, blue: 0.89), stopText: Color(red: 0.77, green: 0, blue: 0.06),
        cardFill: Color(white: 0.95)
    )
}

private let green = Color(red: 0.19, green: 0.82, blue: 0.35)
private let orange = Color(red: 1, green: 0.62, blue: 0.04)
private let yellow = Color(red: 1, green: 0.84, blue: 0.04)

struct PrompterView: View {
    @EnvironmentObject var state: AppState

    private var palette: PrompterPalette { state.prompterIsLight ? .light : .dark }

    var body: some View {
        VStack(spacing: 0) {
            topZone
            mainArea
            if state.alwaysShowControls && state.countdown == nil && !state.showStoppedCard {
                PrompterControlBar(palette: palette)
            }
            if state.cuesEnabled { cueArea }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(panelShape.fill(palette.background))
        .overlay(alignment: .bottom) { levelBeam }
        .clipShape(panelShape)
        .overlay(panelShape.stroke(state.placement == .notch ? Color.clear : palette.separator, lineWidth: 1))
    }

    private var panelShape: UnevenRoundedRectangle {
        let top: CGFloat = state.placement == .notch ? 0 : 20
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: top,
            style: .continuous
        )
    }

    /// The notch itself (or a drag handle when floating), with live labels either side of the camera.
    private var topZone: some View {
        ZStack {
            if state.placement == .floating {
                Capsule().fill(palette.separator).frame(width: 36, height: 4)
                    .help("Drag to move")
            }
            HStack {
                if state.cuesEnabled && state.aiEngine != .claude {
                    Label("On-device · \(state.aiEngine == .gemma ? "Gemma" : "Apple")", systemImage: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(palette.dimText)
                }
                Spacer()
                if state.micActive {
                    liveLabel("LISTENING", color: green).help("Listening to your microphone")
                }
                if state.cuesEnabled {
                    liveLabel("CALL AUDIO", color: orange).help("Listening to call audio for cues")
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: state.topInset)
    }

    private func liveLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 4)
            Text(text).font(.system(size: 9, weight: .bold)).tracking(0.6)
        }
        .foregroundColor(color)
    }

    @ViewBuilder
    private var mainArea: some View {
        let height = CGFloat(state.visibleLines) * state.lineHeight
        Group {
            if let value = state.countdown {
                CountdownView(value: value, palette: palette)
            } else if state.showStoppedCard {
                StoppedCard(palette: palette)
            } else {
                scriptArea
            }
        }
        .frame(height: height)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var scriptArea: some View {
        let lineHeight = state.lineHeight
        return ZStack(alignment: .topLeading) {
            if state.lines.isEmpty {
                Text("Your script is empty. Click the gear to add one.")
                    .font(.system(size: 13))
                    .foregroundColor(palette.dimText)
                    .padding(.horizontal, AppState.horizontalPadding)
            } else {
                ScriptLinesView(
                    words: state.words,
                    lines: state.lines,
                    spoken: state.spokenWordIndex,
                    dimSpoken: state.mode == .voice,
                    fontSize: state.fontSize,
                    lineHeight: lineHeight,
                    textColor: palette.text,
                    dimColor: palette.dimText
                )
                .equatable()
                .padding(.leading, AppState.horizontalPadding + 12)
                .padding(.trailing, AppState.horizontalPadding)
                .offset(y: -state.scrollOffset)

                // Reading marker: a short bar beside the line you should be reading.
                RoundedRectangle(cornerRadius: 2)
                    .fill(state.mode == .voice ? green : palette.marker)
                    .frame(width: 4, height: lineHeight * 0.58)
                    .offset(x: AppState.horizontalPadding, y: CGFloat(state.readingRow) * lineHeight + lineHeight * 0.21)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CGFloat(state.visibleLines) * lineHeight, alignment: .top)
        .clipped()
        .mask(readingFade)
        .overlay(alignment: .bottom) {
            // With the bar hidden, it slides in over the text while the pointer is on the prompter.
            if !state.alwaysShowControls && state.isHovering {
                PrompterControlBar(palette: palette)
                    .background(palette.background.opacity(0.94))
                    .transition(.opacity)
            }
        }
    }

    /// Fades the lines above and below the reading line so the eye stays on it.
    private var readingFade: some View {
        let lines = max(1, state.visibleLines)
        let row = Double(state.readingRow)
        let start = row / Double(lines)
        let end = (row + 1) / Double(lines)
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(lines > 1 && row > 0 ? 0.45 : 1), location: 0),
                .init(color: .black, location: max(0, start - 0.02)),
                .init(color: .black, location: min(1, end + 0.02)),
                .init(color: .black.opacity(lines > row + 1 ? 0.6 : 1), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// A green glow along the bottom edge that pulses with your voice.
    @ViewBuilder
    private var levelBeam: some View {
        if state.micActive {
            let level = CGFloat(state.micLevel)
            Capsule()
                .fill(green)
                .frame(height: 3)
                .padding(.horizontal, 40 + (1 - level) * 80)
                .opacity(0.35 + Double(level) * 0.65)
                .shadow(color: green.opacity(0.9), radius: 6 + level * 10)
                .padding(.bottom, 2)
                .animation(.easeOut(duration: 0.1), value: state.micLevel)
                .allowsHitTesting(false)
        }
    }

    private var cueArea: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("SUGGESTED REPLY").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(yellow.opacity(0.85))
                Spacer(minLength: 8)
                if !state.cueHeard.isEmpty {
                    Text("Heard: “\(state.cueHeard)”")
                        .font(.system(size: 10))
                        .foregroundColor(palette.dimText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if state.cues.isEmpty {
                Text(state.cueStatus.isEmpty ? "Listening for the other side…" : state.cueStatus)
                    .font(.system(size: 12))
                    .foregroundColor(palette.dimText)
                    .lineLimit(3)
            } else {
                ForEach(Array(state.cues.enumerated()), id: \.offset) { index, cue in
                    HStack(spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(yellow.opacity(0.16)))
                        Text(cue).lineLimit(1)
                    }
                    .font(.system(size: 14, weight: index == 0 ? .semibold : .medium))
                    .foregroundColor(yellow.opacity(index == 0 ? 1 : 0.8))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(state.prompterIsLight ? Color(red: 0.2, green: 0.17, blue: 0.02) : Color(red: 0.08, green: 0.07, blue: 0.04))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(yellow.opacity(0.22)))
        )
        .padding(.horizontal, 12)
        .frame(height: AppState.cueAreaHeight - 6, alignment: .top)
        .padding(.bottom, 6)
    }
}

/// 3-2-1 before scrolling or listening starts.
struct CountdownView: View {
    let value: Int
    let palette: PrompterPalette

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(palette.separator, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(value) / 3)
                    .stroke(green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.9), value: value)
                Text("\(value)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(palette.text)
                    .contentTransition(.numericText())
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text("Look at the camera").font(.system(size: 15, weight: .semibold)).foregroundColor(palette.text)
                Text("Press ⌃⌥Esc or Pause to cancel").font(.system(size: 11)).foregroundColor(palette.dimText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting in \(value)")
    }
}

/// Shown after Stop everything, so it's clear that nothing is listening any more.
struct StoppedCard: View {
    @EnvironmentObject var state: AppState
    let palette: PrompterPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "stop.fill")
                .font(.system(size: 11))
                .foregroundColor(palette.stopText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(palette.stopFill))
            VStack(alignment: .leading, spacing: 8) {
                Text("Everything stopped").font(.system(size: 14, weight: .bold)).foregroundColor(palette.text)
                HStack(spacing: 6) {
                    chip("Microphone off")
                    chip("Call audio off")
                    chip("AI cancelled")
                }
                HStack(spacing: 8) {
                    Button("Resume reading") { state.togglePlay() }
                        .buttonStyle(PillButtonStyle(fill: palette.primaryFill, text: palette.primaryText))
                    Button("Hide prompter") {
                        state.dismissStoppedCard()
                        state.isPrompterVisible = false
                    }
                    .buttonStyle(PillButtonStyle(fill: palette.controlFill, text: palette.text))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.cardFill))
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(palette.text.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.controlFill))
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The on-screen controls: everything the keyboard shortcuts do, plus a hard stop.
struct PrompterControlBar: View {
    @EnvironmentObject var state: AppState
    let palette: PrompterPalette

    var body: some View {
        VStack(spacing: 6) {
            ProgressBar(value: state.progress, marks: state.sectionMarks, tint: state.mode == .voice ? green : palette.text.opacity(0.7), track: palette.separator, mark: palette.marker)
            HStack(spacing: 2) {
                PanelButton(icon: "backward.fill", help: "Back one line  ⌃⌥↑", palette: palette) { state.nudge(lines: -1) }
                playButton
                PanelButton(icon: "forward.fill", help: "Forward one line  ⌃⌥↓", palette: palette) { state.nudge(lines: 1) }

                divider

                if state.mode == .timed {
                    PanelButton(icon: "minus", help: "Slower  ⌃⌥−", palette: palette) { state.changeSpeed(by: -5) }
                    Text("\(Int(state.speed))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(palette.control.opacity(0.8))
                        .frame(width: 26)
                        .help("Scroll speed")
                    PanelButton(icon: "plus", help: "Faster  ⌃⌥=", palette: palette) { state.changeSpeed(by: 5) }
                } else {
                    MicMeter(level: state.micActive ? state.micLevel : 0, idle: palette.separator)
                        .frame(width: 84, height: 28)
                        .help("Microphone level")
                }

                divider

                PanelToggle(icon: "mic", isOn: state.mode == .voice, help: "Follow my voice on / off  ⌃⌥V", palette: palette) {
                    state.setMode(state.mode == .voice ? .timed : .voice)
                }
                PanelToggle(icon: "text.bubble", isOn: state.cuesEnabled, help: "Live call cues on / off  ⌃⌥C", palette: palette) {
                    state.toggleCues()
                }
                if !state.sections.isEmpty {
                    sectionMenu
                }

                Spacer(minLength: 4)

                Button { state.hardStop() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(palette.stopText)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 9).fill(palette.stopFill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop everything: scrolling, microphone, call audio and AI  ⌃⌥Esc")
                .accessibilityLabel("Stop everything")

                divider

                PanelButton(icon: "eye.slash", help: "Hide prompter  ⌃⌥H", palette: palette) { state.isPrompterVisible = false }
                PanelButton(icon: "gearshape", help: "Script & settings", palette: palette) { state.onOpenEditor?() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: AppState.controlBarHeight)
    }

    private var playButton: some View {
        let playing = state.isPlaying || state.countdown != nil
        let icon = playing ? (state.mode == .voice ? "mic.slash.fill" : "pause.fill") : (state.mode == .voice ? "mic.fill" : "play.fill")
        let fill: Color = state.mode == .voice && playing ? green : (playing ? palette.primaryFill : green)
        let tint: Color = playing && state.mode == .timed ? palette.primaryText : .black
        let help = state.mode == .voice
            ? (playing ? "Stop listening  ⌃⌥Space" : "Start listening  ⌃⌥Space")
            : (playing ? "Pause  ⌃⌥Space" : "Play  ⌃⌥Space")
        return Button { state.togglePlay() } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 36, height: 28)
                .background(RoundedRectangle(cornerRadius: 9).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var sectionMenu: some View {
        Menu {
            ForEach(state.sections) { section in
                Button("\(section.id + 1).  \(section.title)") { state.jump(toSection: section.id) }
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.control)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 28)
        .help("Jump to a section  ⌃⌥1…9\(state.currentSection.map { " · now: \($0.title)" } ?? "")")
    }

    private var divider: some View {
        Rectangle().fill(palette.separator).frame(width: 1, height: 16).padding(.horizontal, 3)
    }
}

/// Small bar meter showing your microphone level.
private struct MicMeter: View {
    let level: Float
    let idle: Color
    private let weights: [Float] = [0.35, 0.6, 1, 0.75, 0.9, 0.55, 0.4, 0.25]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(level > 0.02 ? green : idle)
                    .frame(width: 3, height: max(4, CGFloat(level * weight) * 22))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

private struct ProgressBar: View {
    let value: Double
    let marks: [Double]
    let tint: Color
    let track: Color
    let mark: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, position in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(mark)
                        .frame(width: 2, height: 7)
                        .offset(x: position * geo.size.width - 1)
                }
            }
        }
        .frame(height: 3)
        .help("Position in script")
    }
}

private struct PanelButton: View {
    let icon: String
    let help: String
    let palette: PrompterPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.control)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.controlFill.opacity(2) : .clear))
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
    let palette: PrompterPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isOn ? .black : palette.control)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? yellow : palette.controlFill))
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
    let textColor: Color
    let dimColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                text(for: line)
                    .font(.system(size: CGFloat(fontSize), weight: .semibold))
                    .tracking(-0.2)
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
        guard dimSpoken else { return Text(verbatim: joined(line.words)).foregroundColor(textColor) }
        let split = min(max(spoken, line.words.lowerBound), line.words.upperBound)
        let done = joined(line.words.lowerBound..<split)
        let rest = joined(split..<line.words.upperBound)
        let separator = (!done.isEmpty && !rest.isEmpty) ? " " : ""
        return Text(verbatim: done + separator).foregroundColor(dimColor)
            + Text(verbatim: rest).foregroundColor(textColor)
    }
}
