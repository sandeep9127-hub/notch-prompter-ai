import AppKit
import Combine
import SwiftUI

enum ScrollMode: String, CaseIterable, Identifiable {
    case timed, voice
    var id: String { rawValue }
    var label: String { self == .timed ? "Auto-scroll" : "Follow my voice" }
}

struct ScriptLine: Identifiable, Equatable {
    let id: Int
    let words: Range<Int>
}

@MainActor
final class AppState: ObservableObject {
    static let horizontalPadding: CGFloat = 18
    static let cueAreaHeight: CGFloat = 74

    private let defaults = UserDefaults.standard

    // Persisted settings
    @Published var script: String { didSet { defaults.set(script, forKey: "script"); relayout() } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize"); relayout() } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    @Published var panelWidth: Double { didSet { defaults.set(panelWidth, forKey: "panelWidth"); relayout() } }
    @Published var visibleLines: Int { didSet { defaults.set(visibleLines, forKey: "visibleLines") } }
    @Published var speechLocale: String { didSet { defaults.set(speechLocale, forKey: "speechLocale") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var aiEngine: AIEngineKind { didSet { defaults.set(aiEngine.rawValue, forKey: "aiEngine") } }
    @Published var gemmaModel: GemmaModel { didSet { defaults.set(gemmaModel.rawValue, forKey: "gemmaModel") } }

    // Prompter state
    @Published var mode: ScrollMode = .timed
    @Published var isPlaying = false
    @Published var isHovering = false
    @Published var isPrompterVisible = true
    @Published var notchHeight: CGFloat = 32
    @Published var scrollOffset: CGFloat = 0
    @Published var spokenWordIndex = 0
    @Published var status = ""

    // Live call cues
    @Published var cuesEnabled = false
    @Published var cues: [String] = []
    @Published var cueStatus = ""

    // AI writer
    @Published var aiBusy = false
    @Published var aiMessage: String?
    @Published var previousScript: String?
    @Published var gemmaStatus = ""

    @Published private(set) var words: [String] = []
    @Published private(set) var lines: [ScriptLine] = []

    let voice = VoiceFollower()
    let cueEngine = LiveCueEngine()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    init() {
        script = defaults.string(forKey: "script") ?? Self.sampleScript
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 22
        speed = defaults.object(forKey: "speed") as? Double ?? 30
        panelWidth = defaults.object(forKey: "panelWidth") as? Double ?? 460
        visibleLines = defaults.object(forKey: "visibleLines") as? Int ?? 3
        speechLocale = defaults.string(forKey: "speechLocale") ?? "en-IN"
        model = defaults.string(forKey: "model") ?? ClaudeClient.defaultModel
        aiEngine = AIEngineKind(rawValue: defaults.string(forKey: "aiEngine") ?? "") ?? .gemma
        gemmaModel = GemmaModel(rawValue: defaults.string(forKey: "gemmaModel") ?? "") ?? .e2b

        GemmaEngine.shared.onStatus = { [weak self] message in
            Task { @MainActor in self?.gemmaStatus = message }
        }

        voice.onWordIndex = { [weak self] index in
            MainActor.assumeIsolated { self?.voiceAdvanced(to: index) }
        }
        voice.onStatus = { [weak self] message in
            MainActor.assumeIsolated {
                self?.status = message
                if !(self?.voice.isRunning ?? false) { self?.isPlaying = false }
            }
        }
        cueEngine.onCues = { [weak self] cues in
            MainActor.assumeIsolated { self?.cues = cues }
        }
        cueEngine.onStatus = { [weak self] message in
            MainActor.assumeIsolated {
                self?.cueStatus = message
                if !(self?.cueEngine.isRunning ?? false) { self?.cuesEnabled = false }
            }
        }
        cueEngine.contextProvider = { [weak self] in
            MainActor.assumeIsolated { self?.script ?? "" }
        }

        relayout()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Layout

    var lineHeight: CGFloat { CGFloat(fontSize * 1.4) }
    var textWidth: CGFloat { CGFloat(panelWidth) - 2 * Self.horizontalPadding }
    var maxOffset: CGFloat { CGFloat(max(0, lines.count - 1)) * lineHeight }
    var panelHeight: CGFloat {
        notchHeight + 6 + CGFloat(visibleLines) * lineHeight + 10 + (cuesEnabled ? Self.cueAreaHeight : 0)
    }

    /// Splits the script into words and greedily packs them into lines that fit the panel width,
    /// so every line has the same height and scrolling maps cleanly to word positions.
    func relayout() {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let space = (" " as NSString).size(withAttributes: attrs).width
        let maxWidth = textWidth
        var newWords: [String] = []
        var newLines: [ScriptLine] = []

        for paragraph in script.components(separatedBy: .newlines) {
            let parts = paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.isEmpty { continue }
            var lineStart = newWords.count
            var width: CGFloat = 0
            for word in parts {
                let wordWidth = (word as NSString).size(withAttributes: attrs).width
                if newWords.count > lineStart && width + space + wordWidth > maxWidth {
                    newLines.append(ScriptLine(id: newLines.count, words: lineStart..<newWords.count))
                    lineStart = newWords.count
                    width = 0
                }
                width += (newWords.count > lineStart ? space : 0) + wordWidth
                newWords.append(word)
            }
            newLines.append(ScriptLine(id: newLines.count, words: lineStart..<newWords.count))
        }

        words = newWords
        lines = newLines
        voice.update(words: newWords)
        spokenWordIndex = min(spokenWordIndex, newWords.count)
        scrollOffset = min(scrollOffset, maxOffset)
    }

    func lineIndex(forWord index: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        if let i = lines.firstIndex(where: { $0.words.contains(index) }) { return i }
        return index <= 0 ? 0 : lines.count - 1
    }

    var currentLine: Int {
        mode == .voice ? lineIndex(forWord: spokenWordIndex) : Int((scrollOffset / lineHeight).rounded())
    }

    // MARK: Playback

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        guard mode == .timed, isPlaying, !isHovering, isPrompterVisible else { return }
        let next = scrollOffset + CGFloat(speed * dt)
        if next >= maxOffset {
            scrollOffset = maxOffset
            isPlaying = false
        } else {
            scrollOffset = next
        }
    }

    func togglePlay() {
        switch mode {
        case .timed:
            if !isPlaying && scrollOffset >= maxOffset { scrollOffset = 0 }
            isPlaying.toggle()
        case .voice:
            if voice.isRunning {
                voice.stop()
                isPlaying = false
            } else {
                let line = lines.indices.contains(currentLine) ? lines[currentLine] : nil
                voice.start(from: line?.words.lowerBound ?? 0, localeID: speechLocale)
                isPlaying = true
            }
        }
    }

    func setMode(_ newMode: ScrollMode) {
        guard newMode != mode else { return }
        let line = currentLine
        voice.stop()
        isPlaying = false
        status = ""
        mode = newMode
        if lines.indices.contains(line) {
            spokenWordIndex = lines[line].words.lowerBound
            voice.jump(to: spokenWordIndex)
        }
    }

    func restart() {
        spokenWordIndex = 0
        voice.jump(to: 0)
        withAnimation(.easeOut(duration: 0.3)) { scrollOffset = 0 }
    }

    func nudge(lines delta: Int) {
        guard !lines.isEmpty else { return }
        let target = min(max(0, currentLine + delta), lines.count - 1)
        if mode == .voice {
            spokenWordIndex = lines[target].words.lowerBound
            voice.jump(to: spokenWordIndex)
        }
        scroll(toLine: target)
    }

    func changeSpeed(by delta: Double) {
        speed = min(150, max(5, speed + delta))
    }

    private func voiceAdvanced(to index: Int) {
        spokenWordIndex = index
        scroll(toLine: lineIndex(forWord: index))
    }

    /// Keeps the line being read on the second row so the previous line stays visible as context.
    private func scroll(toLine line: Int) {
        let leadIn = visibleLines > 2 ? 1 : 0
        let target = min(maxOffset, CGFloat(max(0, line - leadIn)) * lineHeight)
        withAnimation(.easeOut(duration: 0.35)) { scrollOffset = target }
    }

    // MARK: Live cues

    func toggleCues() {
        if cuesEnabled {
            cueEngine.stop()
            cuesEnabled = false
            cues = []
            cueStatus = ""
        } else {
            cuesEnabled = true
            cues = []
            cueEngine.start(localeID: speechLocale)
        }
    }

    // MARK: AI writer

    func aiWrite(notes: String, tone: String, seconds: Int) async {
        await runAI(
            system: Prompts.scriptSystem,
            prompt: Prompts.writeRequest(notes: notes, tone: tone, seconds: seconds)
        )
    }

    func aiPolish(tone: String) async {
        await runAI(system: Prompts.scriptSystem, prompt: Prompts.polishRequest(script: script, tone: tone))
    }

    private func runAI(system: String, prompt: String) async {
        aiBusy = true
        aiMessage = nil
        defer { aiBusy = false }
        do {
            let text = try await AI.complete(system: system, prompt: prompt, long: true, effort: "medium")
            previousScript = script
            script = text.trimmingCharacters(in: .whitespacesAndNewlines)
            restart()
            aiMessage = "Script updated. You'll see it in the Script tab and in the notch."
        } catch {
            aiMessage = error.localizedDescription
        }
    }

    func prepareGemma() {
        Task {
            do { try await GemmaEngine.shared.prepare() } catch {}
        }
    }

    func undoAI() {
        guard let previous = previousScript else { return }
        script = previous
        previousScript = nil
        aiMessage = nil
    }

    static let sampleScript = """
    Welcome to NotchCoach. This text sits right under your camera, so you can read and still look people in the eye.

    Press Control Option Space to start or pause scrolling. Use Control Option Up and Down to move a line, and Control Option plus or minus to change the speed.

    Switch to Follow my voice and the script moves only as you speak. Open the AI writer to turn rough notes into a script you can read aloud.
    """
}
