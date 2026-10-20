import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "NotchCoach"
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = NSHostingView(rootView: EditorView().environmentObject(state))
            newWindow.setContentSize(NSSize(width: 860, height: 640))
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum EditorSection: String, CaseIterable, Identifiable {
    case present, writer, settings, shortcuts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .present: return "Present"
        case .writer: return "AI writer"
        case .settings: return "Settings"
        case .shortcuts: return "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .present: return "play.rectangle"
        case .writer: return "sparkles"
        case .settings: return "gearshape"
        case .shortcuts: return "keyboard"
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var state: AppState
    @State private var section: EditorSection? = .present

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NotchCoach").font(.system(size: 14, weight: .bold))
                        Text("Your script, under your camera").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .selectionDisabled()
                ForEach(EditorSection.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch section ?? .present {
                case .present: PresentView()
                case .writer: AIWriterView()
                case .settings: SettingsTab()
                case .shortcuts: ShortcutsTab().padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: state.editorSectionRequest) {
            if let request = state.editorSectionRequest {
                section = request
                state.editorSectionRequest = nil
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveStatusChips()
            StopEverythingButton(compact: false)
        }
        .padding(12)
    }
}

/// Red stop button that halts scrolling, the microphone, call audio and any AI request.
struct StopEverythingButton: View {
    @EnvironmentObject var state: AppState
    let compact: Bool

    var body: some View {
        Button(role: .destructive) {
            state.hardStop()
        } label: {
            Label(compact ? "Stop" : "Stop everything", systemImage: "stop.fill")
                .frame(maxWidth: compact ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .help("Stops scrolling, the microphone, call audio and any AI request  ⌃⌥Esc")
    }
}

/// Shows at a glance what is live right now. Privacy-sensitive states are coloured.
struct LiveStatusChips: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chip("Microphone", on: state.micActive, color: .green, icon: "mic.fill")
            chip("Call audio", on: state.cuesEnabled, color: .orange, icon: "waveform")
            chip("AI working", on: state.aiBusy, color: .purple, icon: "sparkles")
        }
    }

    private func chip(_ title: String, on: Bool, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 14)
            Text(title)
            Spacer()
            Text(on ? "On" : "Off").fontWeight(.semibold)
        }
        .font(.caption)
        .foregroundColor(on ? color : .secondary)
    }
}

struct PresentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if state.needsScreenPermission { permissionHelp }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        NotchPreview().frame(minWidth: 320, maxWidth: 420)
                        controls
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        NotchPreview()
                        controls
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.08)))

                scriptSection
            }
            .padding(24)
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live call cues need Screen & System Audio Recording", systemImage: "waveform.badge.exclamationmark")
                .font(.headline)
            Text("NotchCoach uses it only to hear the other side of your call. If NotchCoach is already switched on in System Settings but this keeps appearing, the permission belongs to an older version: reset it and allow it again.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open System Settings") { NSWorkspace.shared.open(Permissions.screenRecordingSettings) }
                Button("Reset permission & reopen") {
                    Permissions.resetScreenRecording()
                    Permissions.relaunch()
                }
                .buttonStyle(.borderedProminent)
                Button("Reopen NotchCoach") { Permissions.relaunch() }
                Spacer()
                Button("Dismiss") { state.needsScreenPermission = false }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.35)))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Button { state.nudge(lines: -1) } label: { Image(systemName: "backward.fill").frame(width: 18) }
                    .help("Back one line  ⌃⌥↑")
                Button { state.togglePlay() } label: {
                    Label(playTitle, systemImage: playIcon).frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.mode == .voice ? .green : .accentColor)
                .help(state.mode == .voice ? "Start / stop listening  ⌃⌥Space" : "Play / pause  ⌃⌥Space")
                Button { state.nudge(lines: 1) } label: { Image(systemName: "forward.fill").frame(width: 18) }
                    .help("Forward one line  ⌃⌥↓")
                Button { state.restart() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    .help("Back to the top  ⌃⌥R")
            }
            .controlSize(.large)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Toggle("Show prompter", isOn: $state.isPrompterVisible).help("⌃⌥H")
                    Toggle("Follow my voice", isOn: Binding(
                        get: { state.mode == .voice },
                        set: { state.setMode($0 ? .voice : .timed) }
                    ))
                    .help("Scroll only as you speak  ⌃⌥V")
                }
                GridRow {
                    Toggle("Live call cues", isOn: Binding(
                        get: { state.cuesEnabled },
                        set: { _ in state.toggleCues() }
                    ))
                    .help("Suggest replies from what others say  ⌃⌥C")
                    Toggle("Controls on prompter", isOn: $state.alwaysShowControls)
                        .help("Always show buttons under the script")
                }
                GridRow {
                    Toggle("3-second countdown", isOn: $state.countdownEnabled)
                        .help("Count down 3, 2, 1 before scrolling or listening starts")
                    Toggle("Pause when I hover", isOn: $state.pauseOnHover)
                        .help("Auto-scroll pauses while the pointer is on the prompter")
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 24) {
                LabeledSlider(title: "Speed", value: $state.speed, range: 5...150, display: state.mode == .voice ? "Voice" : "\(Int(state.speed))")
                    .disabled(state.mode == .voice)
                    .help(state.mode == .voice ? "Speed follows your voice" : "⌃⌥= faster, ⌃⌥− slower")
                LabeledSlider(title: "Text size", value: $state.fontSize, range: 14...40, display: "\(Int(state.fontSize)) pt")
            }

            if !state.status.isEmpty {
                Label(state.status, systemImage: "info.circle").font(.callout).foregroundColor(.secondary)
            }
            if state.cuesEnabled && !state.cueStatus.isEmpty {
                Label(state.cueStatus, systemImage: "text.bubble").font(.callout).foregroundColor(.secondary)
            }
        }
    }

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Script").font(.title3.weight(.bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.sections) { section in
                            sectionButton(section)
                        }
                    }
                }
                Spacer(minLength: 8)
                Text("\(state.wordCount) words · about \(state.readingTime) to read")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
            TextEditor(text: $state.script)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 280)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
            Text("Tip: start a line with # to make a section you can jump to, like “# Results”.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func sectionButton(_ section: ScriptSection) -> some View {
        let current = state.currentSection?.id == section.id
        let button = Button { state.jump(toSection: section.id) } label: {
            HStack(spacing: 6) {
                if section.id < 9 {
                    Text("⌘\(section.id + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
                Text(section.title).lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .tint(current ? Color.yellow : nil)
        .help("Jump to “\(section.title)”  ⌃⌥\(section.id + 1) anywhere")
        if section.id < 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(section.id + 1)")), modifiers: .command)
        } else {
            button
        }
    }

    private var playTitle: String {
        if state.countdown != nil { return "Cancel countdown" }
        switch (state.mode, state.isPlaying) {
        case (.voice, true): return "Stop listening"
        case (.voice, false): return "Start listening"
        case (.timed, true): return "Pause"
        case (.timed, false): return "Play"
        }
    }

    private var playIcon: String {
        if state.countdown != nil { return "xmark" }
        if state.isPlaying { return state.mode == .voice ? "mic.slash.fill" : "pause.fill" }
        return state.mode == .voice ? "mic.fill" : "play.fill"
    }
}

/// A small live copy of what the prompter is showing.
struct NotchPreview: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.placement == .notch ? "IN YOUR NOTCH NOW" : "ON SCREEN NOW")
                    .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
                Spacer()
                Text(statusText).font(.system(size: 11, weight: .semibold)).foregroundColor(statusColor)
            }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.08))
                VStack(alignment: .leading, spacing: 3) {
                    if let value = state.countdown {
                        Text("Starting in \(value)…").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    } else if state.lines.isEmpty {
                        Text("No script yet").font(.system(size: 14)).foregroundColor(.gray)
                    } else {
                        ForEach(Array(state.previewLines.enumerated()), id: \.offset) { index, line in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index == state.readingRow ? (state.mode == .voice ? Color.green : Color.yellow) : .clear)
                                    .frame(width: 3, height: 13)
                                Text(line).lineLimit(1)
                                    .foregroundColor(index == state.readingRow ? .white : .white.opacity(0.4))
                            }
                            .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(state.mode == .voice ? Color.green : Color.white.opacity(0.7))
                                .frame(width: max(0, min(1, state.progress)) * geo.size.width)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 6)
                }
                .padding(EdgeInsets(top: 24, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous).fill(Color.black))
                .padding(.horizontal, 22)
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let section = state.currentSection {
                Text("Section: \(section.title)").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var statusText: String {
        if state.countdown != nil { return "● Counting down" }
        if state.mode == .voice { return state.isPlaying ? "● Following your voice" : "Voice · not listening" }
        return state.isPlaying ? "● Auto-scrolling" : "Paused"
    }

    private var statusColor: Color {
        state.isPlaying || state.countdown != nil ? .green : .secondary
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text(display).font(.callout.monospacedDigit()).foregroundColor(.secondary).frame(width: 48, alignment: .trailing)
        }
    }
}

struct AIWriterView: View {
    @EnvironmentObject var state: AppState
    @State private var notes = ""
    @State private var tone = "Conversational"
    @State private var seconds = 60

    private let tones = ["Conversational", "Professional", "Warm", "Energetic", "Concise"]
    private let lengths: [(Int, String)] = [(30, "30 sec"), (60, "1 min"), (120, "2 min"), (300, "5 min")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Turn rough notes into a script you can read aloud.").font(.headline)
                Spacer()
                Label(state.aiEngine.label, systemImage: "cpu")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help("Change the AI engine in Settings")
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    notesPane
                    if state.aiDraft != nil || state.aiBusy { draftPane }
                }
                VStack(spacing: 16) {
                    notesPane
                    if state.aiDraft != nil || state.aiBusy { draftPane }
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Tone").fixedSize()
                    Picker("Tone", selection: $tone) {
                        ForEach(tones, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                HStack(spacing: 8) {
                    Text("Length").fixedSize()
                    Picker("Length", selection: $seconds) {
                        ForEach(lengths, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    state.aiWrite(notes: notes, tone: tone, seconds: seconds)
                } label: {
                    Label("Write script from notes", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.aiBusy || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Writes a new draft from the notes on the left")

                Button {
                    state.aiPolish(tone: tone)
                } label: {
                    Label("Polish my current script", systemImage: "wand.and.stars")
                }
                .disabled(state.aiBusy || state.script.isEmpty)
                .help("Rewrites the script that's in the prompter now, as a draft for you to review")

                if state.aiBusy {
                    Button("Cancel") { state.cancelAI() }
                }
                Spacer()
                if state.previousScript != nil && state.aiDraft == nil {
                    Button { state.undoAI() } label: { Label("Undo last change", systemImage: "arrow.uturn.backward") }
                        .help("Put back the script you had before using the last AI draft")
                }
            }
            .controlSize(.large)

            if let message = state.aiMessage {
                Label(message, systemImage: "info.circle").font(.callout).foregroundColor(.secondary)
            }
            if state.aiEngine == .gemma && !state.gemmaStatus.isEmpty && state.aiBusy {
                Label(state.gemmaStatus, systemImage: "arrow.down.circle").font(.callout).foregroundColor(.secondary)
            }
        }
        .padding(24)
    }

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR NOTES").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
            TextEditor(text: $notes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Paste bullet points or rough notes here…")
                            .foregroundColor(.secondary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        }
        .frame(minWidth: 280)
    }

    private var draftPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI DRAFT").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
                Spacer()
                if let draft = state.aiDraft {
                    let words = draft.split(whereSeparator: { $0.isWhitespace }).count
                    Text("\(words) words · about \(max(1, Int((Double(words) / 140 * 60).rounded()))) sec")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Group {
                if state.aiBusy {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Writing your draft…").font(.callout).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: Binding(get: { state.aiDraft ?? "" }, set: { state.aiDraft = $0 }))
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
            }
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.45)))

            if state.aiDraft != nil && !state.aiBusy {
                HStack(spacing: 8) {
                    Button { state.useDraft() } label: { Label("Use this script", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .help("Replaces the script in your prompter. You can undo it.")
                    Button { state.aiTryAgain() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button("Discard") { state.discardDraft() }
                        .buttonStyle(.borderless)
                }
                Text("You can edit the draft before using it.").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 280)
    }
}

struct SettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey = ""
    @State private var saved = false
    @AppStorage("claudeWorkspaceID") private var workspaceID = ""

    private let locales: [(String, String)] = [
        ("en-IN", "English (India)"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("hi-IN", "Hindi"),
    ]

    var body: some View {
        Form {
            Section("AI engine") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { engineCards }
                    VStack(spacing: 10) { engineCards }
                }
                .padding(.vertical, 4)

                switch state.aiEngine {
                case .gemma: gemmaSettings
                case .claude: claudeSettings
                case .apple: appleSettings
                }
            }

            Section("Appearance") {
                Picker("Window", selection: $state.appearance) {
                    ForEach(WindowAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Prompter", selection: $state.placement) {
                    ForEach(PrompterPlacement.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(placementHelp)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Prompter") {
                Slider(value: $state.fontSize, in: 14...40, step: 1) { Text("Text size: \(Int(state.fontSize))") }
                Slider(value: $state.speed, in: 5...150, step: 1) { Text("Scroll speed: \(Int(state.speed))") }
                Slider(value: $state.panelWidth, in: 460...800, step: 10) { Text("Width: \(Int(state.panelWidth))") }
                Stepper("Visible lines: \(state.visibleLines)", value: $state.visibleLines, in: 1...6)
                Toggle("Always show controls on the prompter", isOn: $state.alwaysShowControls)
                Toggle("3-second countdown before starting", isOn: $state.countdownEnabled)
                Toggle("Pause auto-scroll while the pointer is on the prompter", isOn: $state.pauseOnHover)
            }

            Section("Speech") {
                Picker("Language", selection: $state.speechLocale) {
                    ForEach(locales, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text("Used for Follow my voice and live call cues. Recognition runs on your Mac when the language supports it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = Keychain.apiKey ?? ""
            saved = !apiKey.isEmpty
        }
        .onChange(of: apiKey) { saved = false }
    }

    private var placementHelp: String {
        switch state.placement {
        case .notch: return "Sits in the notch, right under the camera. It's always black so it blends with the notch."
        case .floating: return "A card you can drag anywhere by its top handle. Follows the window appearance."
        case .display: return "Top centre of your second display, for an external camera. Follows the window appearance."
        }
    }

    @ViewBuilder
    private var engineCards: some View {
        EngineCard(kind: .gemma, title: "Gemma", detail: "Runs on this Mac. Nothing you write or hear leaves it.", tag: "Free · Private", tagColor: .green)
        EngineCard(kind: .claude, title: "Claude", detail: "Best writing quality, with your own Anthropic API key.", tag: "Pay per use", tagColor: .blue)
        EngineCard(kind: .apple, title: "Apple Intelligence", detail: "Apple's built-in model. No download needed.", tag: "Free · macOS 26", tagColor: .gray)
    }

    @ViewBuilder
    private var gemmaSettings: some View {
        Picker("Model size", selection: $state.gemmaModel) {
            Text("E2B · faster, lighter").tag(GemmaModel.e2b)
            Text("E4B · better writing").tag(GemmaModel.e4b)
        }
        .pickerStyle(.segmented)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(GemmaEngine.isDownloaded ? "Load model" : "Download model") { state.prepareGemma() }
                if !state.gemmaStatus.isEmpty {
                    Text(state.gemmaStatus).font(.callout).foregroundColor(.secondary)
                }
            }
            if let progress = state.gemmaProgress, progress < 1 {
                ProgressView(value: progress)
            }
        }
        Text("A one-time download of a few GB from Hugging Face. It uses a few GB of memory while loaded.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var claudeSettings: some View {
        HStack {
            SecureField("Anthropic API key (sk-ant-…)", text: $apiKey)
            Button(saved ? "Saved" : "Save") {
                Keychain.apiKey = apiKey
                saved = true
                // A saved key means the user wants Claude, which writes better than the local models.
                if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty { state.aiEngine = .claude }
            }
        }
        Picker("Model", selection: $state.model) {
            ForEach(ClaudeClient.models, id: \.id) { Text($0.label).tag($0.id) }
        }
        TextField("Workspace ID (optional, wrkspc_…)", text: $workspaceID)
            .textFieldStyle(.roundedBorder)
        Text("Only needed if your key isn't tied to a workspace. Find the ID in the Claude Console under Settings → Workspaces.")
            .font(.caption)
            .foregroundColor(.secondary)
        Text("Get a key at console.anthropic.com; it's stored in your macOS Keychain. Script text and call transcripts are sent to Anthropic when you use the AI writer or live cues.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var appleSettings: some View {
        if let reason = AppleEngine.unavailableReason {
            Label(reason, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
        } else {
            Label("Apple Intelligence is ready on this Mac.", systemImage: "checkmark.circle").foregroundColor(.green)
        }
        Text("No download, and nothing leaves your Mac. It has a small memory window, so very long scripts may need Gemma or Claude.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

/// One selectable AI engine, drawn as a card.
struct EngineCard: View {
    @EnvironmentObject var state: AppState
    let kind: AIEngineKind
    let title: String
    let detail: String
    let tag: String
    let tagColor: Color

    var body: some View {
        let selected = state.aiEngine == kind
        Button { state.aiEngine = kind } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .bold))
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(selected ? .primary : .secondary)
                }
                Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(tag)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tagColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tagColor.opacity(0.14)))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.primary : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct ShortcutsTab: View {
    private let rows: [(String, String)] = [
        ("⌃⌥ Space", "Play / pause (or start / stop listening)"),
        ("⌃⌥ ↑ / ↓", "Move back / forward one line"),
        ("⌃⌥ = / −", "Faster / slower auto-scroll"),
        ("⌃⌥ R", "Restart from the top"),
        ("⌃⌥ V", "Switch between Auto-scroll and Follow my voice"),
        ("⌃⌥ C", "Live call cues on / off"),
        ("⌃⌥ H", "Show / hide the prompter"),
        ("⌃⌥ Esc", "Stop everything: scrolling, microphone, call audio and AI"),
        ("⌃⌥ 1…9", "Jump to a section (lines starting with #)"),
        ("⌘ 1…9", "Jump to a section, while this window is open"),
        ("Hover", "Hovering over the prompter pauses auto-scroll"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0).font(.system(.body, design: .monospaced)).frame(width: 110, alignment: .leading)
                    Text(row.1)
                }
            }
            Divider().padding(.vertical, 6)
            Text("Every shortcut also has a button: on the prompter's control bar, in the Present screen and in the menu bar icon.")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("The prompter is excluded from screen sharing and recordings. Test it once with your meeting app before relying on it.")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
