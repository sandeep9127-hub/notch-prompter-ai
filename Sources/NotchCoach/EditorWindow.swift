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
            List(EditorSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
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
        VStack(alignment: .leading, spacing: 16) {
            controls
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Script").font(.headline)
                    Spacer()
                    Text("\(state.wordCount) words · about \(state.readingTime) to read")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TextEditor(text: $state.script)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
            }
        }
        .padding(24)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { state.nudge(lines: -1) } label: { Image(systemName: "backward.fill") }
                    .help("Back one line  ⌃⌥↑")
                Button { state.togglePlay() } label: {
                    Label(playTitle, systemImage: playIcon).frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .help(state.mode == .voice ? "Start / stop listening  ⌃⌥Space" : "Play / pause  ⌃⌥Space")
                Button { state.nudge(lines: 1) } label: { Image(systemName: "forward.fill") }
                    .help("Forward one line  ⌃⌥↓")
                Button { state.restart() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    .help("Back to the top  ⌃⌥R")
                Spacer()
                StopEverythingButton(compact: true)
            }
            .controlSize(.large)

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    Toggle("Show prompter", isOn: $state.isPrompterVisible)
                        .help("⌃⌥H")
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
                    .help("Suggest talking points from what others say  ⌃⌥C")
                    Toggle("Controls on prompter", isOn: $state.alwaysShowControls)
                        .help("Always show buttons under the script in the notch")
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 24) {
                LabeledSlider(title: "Speed", value: $state.speed, range: 5...150, display: "\(Int(state.speed))")
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
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var playTitle: String {
        switch (state.mode, state.isPlaying) {
        case (.voice, true): return "Stop listening"
        case (.voice, false): return "Start listening"
        case (.timed, true): return "Pause"
        case (.timed, false): return "Play"
        }
    }

    private var playIcon: String {
        if state.isPlaying { return state.mode == .voice ? "mic.slash.fill" : "pause.fill" }
        return state.mode == .voice ? "mic.fill" : "play.fill"
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
                Label(state.aiEngine.label, systemImage: "cpu").font(.caption).foregroundColor(.secondary)
            }

            TextEditor(text: $notes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Paste bullet points or notes here…")
                            .foregroundColor(.secondary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))

            HStack(spacing: 16) {
                Picker("Tone", selection: $tone) {
                    ForEach(tones, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
                Picker("Length", selection: $seconds) {
                    ForEach(lengths, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    state.aiWrite(notes: notes, tone: tone, seconds: seconds)
                } label: {
                    Label("Write script", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.aiBusy || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    state.aiPolish(tone: tone)
                } label: {
                    Label("Polish current script", systemImage: "wand.and.stars")
                }
                .disabled(state.aiBusy || state.script.isEmpty)

                if state.aiBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { state.cancelAI() }
                }
                Spacer()
                if state.previousScript != nil {
                    Button { state.undoAI() } label: { Label("Undo AI change", systemImage: "arrow.uturn.backward") }
                }
            }
            .controlSize(.large)

            if let message = state.aiMessage {
                Label(message, systemImage: "info.circle").font(.callout).foregroundColor(.secondary)
            }
            if state.aiEngine == .gemma && !state.gemmaStatus.isEmpty {
                Label(state.gemmaStatus, systemImage: "arrow.down.circle").font(.callout).foregroundColor(.secondary)
            }
        }
        .padding(24)
    }
}

struct SettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var apiKey = ""
    @State private var saved = false

    private let locales: [(String, String)] = [
        ("en-IN", "English (India)"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("hi-IN", "Hindi"),
    ]

    var body: some View {
        Form {
            Section("AI engine") {
                Picker("Use", selection: $state.aiEngine) {
                    ForEach(AIEngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                switch state.aiEngine {
                case .gemma: gemmaSettings
                case .claude: claudeSettings
                case .apple: appleSettings
                }
            }

            Section("Prompter") {
                Slider(value: $state.fontSize, in: 14...40, step: 1) { Text("Text size: \(Int(state.fontSize))") }
                Slider(value: $state.speed, in: 5...150, step: 1) { Text("Scroll speed: \(Int(state.speed))") }
                Slider(value: $state.panelWidth, in: 420...800, step: 10) { Text("Width: \(Int(state.panelWidth))") }
                Stepper("Visible lines: \(state.visibleLines)", value: $state.visibleLines, in: 1...6)
                Toggle("Always show controls on the prompter", isOn: $state.alwaysShowControls)
                Text("When off, the controls appear only while the pointer is over the prompter.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    @ViewBuilder
    private var gemmaSettings: some View {
        Picker("Model", selection: $state.gemmaModel) {
            ForEach(GemmaModel.allCases) { Text($0.label).tag($0) }
        }
        HStack {
            Button("Download / load model") { state.prepareGemma() }
            if !state.gemmaStatus.isEmpty {
                Text(state.gemmaStatus).font(.callout).foregroundColor(.secondary)
            }
        }
        Text("Runs entirely on this Mac: nothing you write or hear is sent anywhere. The model downloads once from Hugging Face (a few GB) and uses a few GB of memory while loaded.")
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
            }
        }
        Picker("Model", selection: $state.model) {
            ForEach(ClaudeClient.models, id: \.id) { Text($0.label).tag($0.id) }
        }
        Text("Best quality, paid per use. Get a key at console.anthropic.com; it's stored in your macOS Keychain. Script text and call transcripts are sent to Anthropic when you use the AI writer or live cues.")
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
        Text("Uses Apple's built-in on-device model: no download and nothing leaves your Mac. It has a small memory window, so very long scripts may need Gemma or Claude.")
            .font(.caption)
            .foregroundColor(.secondary)
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
