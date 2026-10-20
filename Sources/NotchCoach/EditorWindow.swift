import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "NotchCoach"
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = NSHostingView(rootView: EditorView().environmentObject(state))
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct EditorView: View {
    var body: some View {
        TabView {
            ScriptTab().tabItem { Text("Script") }
            AIWriterTab().tabItem { Text("AI writer") }
            SettingsTab().tabItem { Text("Settings") }
            ShortcutsTab().tabItem { Text("Shortcuts") }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }
}

struct ScriptTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $state.script)
                .font(.system(size: 15))
                .border(Color.secondary.opacity(0.3))

            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { state.mode }, set: { state.setMode($0) })) {
                    ForEach(ScrollMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Button(state.isPlaying ? "Pause" : (state.mode == .voice ? "Start listening" : "Play")) {
                    state.togglePlay()
                }
                Button("Restart") { state.restart() }
                Spacer()
            }

            HStack(spacing: 20) {
                Toggle("Show prompter", isOn: $state.isPrompterVisible)
                Toggle("Live call cues", isOn: Binding(get: { state.cuesEnabled }, set: { _ in state.toggleCues() }))
                Spacer()
            }

            if !state.status.isEmpty {
                Text(state.status).font(.callout).foregroundColor(.secondary)
            }
            if state.cuesEnabled && !state.cueStatus.isEmpty {
                Text("Cues: \(state.cueStatus)").font(.callout).foregroundColor(.secondary)
            }
        }
    }
}

struct AIWriterTab: View {
    @EnvironmentObject var state: AppState
    @State private var notes = ""
    @State private var tone = "Conversational"
    @State private var seconds = 60

    private let tones = ["Conversational", "Professional", "Warm", "Energetic", "Concise"]
    private let lengths: [(Int, String)] = [(30, "30 sec"), (60, "1 min"), (120, "2 min"), (300, "5 min")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste bullet points or rough notes. Claude turns them into a script you can read aloud.")
                .foregroundColor(.secondary)
            TextEditor(text: $notes)
                .font(.system(size: 14))
                .border(Color.secondary.opacity(0.3))

            HStack {
                Picker("Tone", selection: $tone) {
                    ForEach(tones, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
                Picker("Length", selection: $seconds) {
                    ForEach(lengths, id: \.0) { Text($0.1).tag($0.0) }
                }
                .frame(width: 180)
                Spacer()
            }

            HStack {
                Button("Write script from notes") {
                    Task { await state.aiWrite(notes: notes, tone: tone, seconds: seconds) }
                }
                .disabled(state.aiBusy || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Polish current script") {
                    Task { await state.aiPolish(tone: tone) }
                }
                .disabled(state.aiBusy || state.script.isEmpty)

                if state.previousScript != nil {
                    Button("Undo AI change") { state.undoAI() }
                }
                if state.aiBusy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let message = state.aiMessage {
                Text(message).font(.callout).foregroundColor(.secondary)
            }
        }
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
            Section("Claude") {
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
                Text("Get a key at console.anthropic.com. It's stored in your macOS Keychain. Script text and call transcripts are sent to Anthropic only when you use the AI writer or live cues.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Prompter") {
                Slider(value: $state.fontSize, in: 14...40, step: 1) { Text("Text size: \(Int(state.fontSize))") }
                Slider(value: $state.speed, in: 5...150, step: 1) { Text("Scroll speed: \(Int(state.speed))") }
                Slider(value: $state.panelWidth, in: 360...800, step: 10) { Text("Width: \(Int(state.panelWidth))") }
                Stepper("Visible lines: \(state.visibleLines)", value: $state.visibleLines, in: 1...6)
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
            Text("The prompter is excluded from screen sharing and recordings. Test it once with your meeting app before relying on it.")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
