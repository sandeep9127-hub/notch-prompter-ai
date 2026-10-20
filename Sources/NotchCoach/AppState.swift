import AppKit
import Combine
import SwiftUI

enum ScrollMode: String, CaseIterable, Identifiable {
    case timed, voice
    var id: String { rawValue }
    var label: String { self == .timed ? "Auto-scroll" : "Follow my voice" }
}

/// Where the prompter appears.
enum PrompterPlacement: String, CaseIterable, Identifiable {
    case notch, floating, display
    var id: String { rawValue }

    var label: String {
        switch self {
        case .notch: return "In the notch"
        case .floating: return "Floating window"
        case .display: return "Other display"
        }
    }
}

/// Light or dark for the windows and the floating prompters. The notch prompter is always black.
enum WindowAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ScriptLine: Identifiable, Equatable {
    let id: Int
    let words: Range<Int>
}

/// A `# Heading` line in the script. It isn't shown in the prompter; it marks a place to jump to.
struct ScriptSection: Identifiable, Equatable {
    let id: Int
    let title: String
    let wordIndex: Int
}

@MainActor
final class AppState: ObservableObject {
    static let horizontalPadding: CGFloat = 18
    static let cueAreaHeight: CGFloat = 132
    static let controlBarHeight: CGFloat = 44
    static let handleHeight: CGFloat = 22

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
    @Published var alwaysShowControls: Bool { didSet { defaults.set(alwaysShowControls, forKey: "alwaysShowControls") } }
    @Published var countdownEnabled: Bool { didSet { defaults.set(countdownEnabled, forKey: "countdownEnabled") } }
    @Published var pauseOnHover: Bool { didSet { defaults.set(pauseOnHover, forKey: "pauseOnHover") } }
    @Published var placement: PrompterPlacement { didSet { defaults.set(placement.rawValue, forKey: "placement"); refreshAppearance() } }
    @Published var appearance: WindowAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); refreshAppearance() } }

    // Prompter state
    @Published var mode: ScrollMode = .timed
    @Published var isPlaying = false
    @Published var isHovering = false
    @Published var isPrompterVisible = true
    @Published var notchHeight: CGFloat = 32
    @Published var scrollOffset: CGFloat = 0
    @Published var spokenWordIndex = 0
    @Published var status = ""
    @Published var micActive = false
    @Published var micLevel: Float = 0
    @Published var countdown: Int?
    @Published var showStoppedCard = false
    /// True when a floating prompter should be drawn light.
    @Published private(set) var prompterIsLight = false

    // Live call cues
    @Published var cuesEnabled = false
    @Published var cues: [String] = []
    @Published var cueHeard = ""
    /// What the call audio is saying right now, shown live in the cue card.
    @Published var cueHearing = ""
    @Published var cueStatus = ""
    @Published var needsScreenPermission = false

    // AI writer
    @Published var aiBusy = false
    @Published var aiMessage: String?
    @Published var previousScript: String?
    /// The AI's latest result, shown for review before it replaces the script.
    @Published var aiDraft: String?
    /// Asks the editor window to switch to a section (for example after using a draft).
    @Published var editorSectionRequest: EditorSection?
    private var lastAIRequest: (system: String, prompt: String)?
    @Published var gemmaStatus = ""
    @Published var gemmaProgress: Double?

    @Published private(set) var words: [String] = []
    @Published private(set) var lines: [ScriptLine] = []
    @Published private(set) var sections: [ScriptSection] = []

    /// Set by the app delegate so the prompter's gear button can open the editor.
    var onOpenEditor: (() -> Void)?
    private var aiTask: Task<Void, Never>?
    private var countdownTimer: Timer?
    private var stoppedCardTimer: Timer?
    private var themeObserver: NSObjectProtocol?

    let voice = VoiceFollower()
    let cueEngine = LiveCueEngine()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    init() {
        script = defaults.string(forKey: "script") ?? Self.sampleScript
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 22
        speed = defaults.object(forKey: "speed") as? Double ?? 30
        panelWidth = max(460, defaults.object(forKey: "panelWidth") as? Double ?? 500)
        visibleLines = defaults.object(forKey: "visibleLines") as? Int ?? 3
        speechLocale = defaults.string(forKey: "speechLocale") ?? "en-IN"
        model = defaults.string(forKey: "model") ?? ClaudeClient.defaultModel
        // Prefer Claude once an API key has been added, unless Gemma is already downloaded and chosen.
        let hasClaudeKey = !(Keychain.apiKey ?? "").isEmpty
        let storedEngine = AIEngineKind(rawValue: defaults.string(forKey: "aiEngine") ?? "")
        if hasClaudeKey && (storedEngine == nil || (storedEngine == .gemma && !GemmaEngine.isDownloaded)) {
            aiEngine = .claude
        } else {
            aiEngine = storedEngine ?? .gemma
        }
        gemmaModel = GemmaModel(rawValue: defaults.string(forKey: "gemmaModel") ?? "") ?? .e2b
        alwaysShowControls = defaults.object(forKey: "alwaysShowControls") as? Bool ?? true
        countdownEnabled = defaults.object(forKey: "countdownEnabled") as? Bool ?? true
        pauseOnHover = defaults.object(forKey: "pauseOnHover") as? Bool ?? true
        placement = PrompterPlacement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .notch
        appearance = WindowAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system

        GemmaEngine.shared.onStatus = { [weak self] message in
            Task { @MainActor in self?.gemmaStatusChanged(message) }
        }

        voice.onWordIndex = { [weak self] index in
            MainActor.assumeIsolated { self?.voiceAdvanced(to: index) }
        }
        voice.onStatus = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = message
                self.micActive = self.voice.isRunning
                if !self.voice.isRunning {
                    self.isPlaying = false
                    self.micLevel = 0
                }
            }
        }
        voice.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                guard let self, self.micActive else { return }
                // Rise fast, fall slowly, so the glow feels alive without flicker.
                self.micLevel = level > self.micLevel ? level : self.micLevel * 0.7 + level * 0.3
            }
        }
        cueEngine.onCues = { [weak self] cues, heard in
            MainActor.assumeIsolated {
                self?.cues = cues
                self?.cueHeard = heard
            }
        }
        cueEngine.onStatus = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cueStatus = message
                if !self.cueEngine.isRunning {
                    self.cuesEnabled = false
                    // Keep problems such as missing permissions on screen after cues switch off.
                    if !message.isEmpty { self.status = message }
                }
            }
        }
        cueEngine.onHearing = { [weak self] text in
            MainActor.assumeIsolated { self?.cueHearing = text }
        }
        cueEngine.onPermissionMissing = { [weak self] in
            MainActor.assumeIsolated {
                self?.needsScreenPermission = true
                self?.onOpenEditor?()
            }
        }
        cueEngine.contextProvider = { [weak self] in
            MainActor.assumeIsolated { self?.script ?? "" }
        }

        relayout()
        refreshAppearance()
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Appearance

    func refreshAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
        let systemIsLight = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
        let light = appearance == .light || (appearance == .system && systemIsLight)
        prompterIsLight = placement != .notch && light
    }

    // MARK: Layout

    var lineHeight: CGFloat { CGFloat(fontSize * 1.4) }
    var textWidth: CGFloat { CGFloat(panelWidth) - 2 * Self.horizontalPadding - 12 }
    var maxOffset: CGFloat { CGFloat(max(0, lines.count - 1)) * lineHeight }
    var topInset: CGFloat { placement == .notch ? notchHeight : Self.handleHeight }
    var panelHeight: CGFloat {
        topInset + 6 + CGFloat(visibleLines) * lineHeight + 10
            + (cuesEnabled ? Self.cueAreaHeight : 0)
            + (alwaysShowControls ? Self.controlBarHeight : 0)
    }

    /// Splits the script into words and greedily packs them into lines that fit the panel width,
    /// so every line has the same height and scrolling maps cleanly to word positions.
    /// Lines starting with `#` become sections instead of text.
    func relayout() {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let space = (" " as NSString).size(withAttributes: attrs).width
        let maxWidth = textWidth
        var newWords: [String] = []
        var newLines: [ScriptLine] = []
        var newSections: [ScriptSection] = []

        for paragraph in script.components(separatedBy: .newlines) {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    newSections.append(ScriptSection(id: newSections.count, title: title, wordIndex: newWords.count))
                }
                continue
            }
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
        sections = newSections.filter { $0.wordIndex < max(1, newWords.count) }
        voice.update(words: newWords)
        spokenWordIndex = min(spokenWordIndex, newWords.count)
        scrollOffset = min(scrollOffset, maxOffset)
    }

    func lineIndex(forWord index: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        if let i = lines.firstIndex(where: { $0.words.contains(index) }) { return i }
        return index <= 0 ? 0 : lines.count - 1
    }

    /// How far through the script the reader is, from 0 to 1.
    var progress: Double {
        if mode == .voice { return words.isEmpty ? 0 : Double(spokenWordIndex) / Double(words.count) }
        return maxOffset > 0 ? Double(scrollOffset / maxOffset) : 0
    }

    /// Where each section starts, from 0 to 1, for the ticks on the progress bar.
    var sectionMarks: [Double] {
        guard !words.isEmpty else { return [] }
        return sections.map { Double($0.wordIndex) / Double(words.count) }.filter { $0 > 0.001 }
    }

    var currentSection: ScriptSection? {
        let word = mode == .voice ? spokenWordIndex : (lines.indices.contains(currentLine) ? lines[currentLine].words.lowerBound : 0)
        return sections.last(where: { $0.wordIndex <= word })
    }

    var wordCount: Int { words.count }

    /// Reading time at a typical speaking pace of 140 words a minute.
    var readingTime: String {
        let seconds = Int((Double(words.count) / 140.0 * 60).rounded())
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min \(seconds % 60) sec"
    }

    var currentLine: Int {
        mode == .voice ? lineIndex(forWord: spokenWordIndex) : Int((scrollOffset / lineHeight).rounded())
    }

    /// The row of the visible window that holds the line being read.
    var readingRow: Int { visibleLines > 2 ? 1 : 0 }

    /// A few lines around the reading position, for the preview in the editor.
    var previewLines: [String] {
        guard !lines.isEmpty else { return [] }
        let start = max(0, currentLine - readingRow)
        let end = min(lines.count, start + 3)
        return lines[start..<end].map { words[$0.words].joined(separator: " ") }
    }

    // MARK: Playback

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        guard mode == .timed, isPlaying, countdown == nil, isPrompterVisible else { return }
        if pauseOnHover && isHovering { return }
        let next = scrollOffset + CGFloat(speed * dt)
        if next >= maxOffset {
            scrollOffset = maxOffset
            isPlaying = false
        } else {
            scrollOffset = next
        }
    }

    func togglePlay() {
        dismissStoppedCard()
        if countdown != nil {
            cancelCountdown()
            return
        }
        switch mode {
        case .timed:
            if isPlaying {
                isPlaying = false
            } else {
                if scrollOffset >= maxOffset { scrollOffset = 0 }
                withCountdown { [weak self] in self?.isPlaying = true }
            }
        case .voice:
            if voice.isRunning {
                voice.stop()
                isPlaying = false
            } else {
                let start = lines.indices.contains(currentLine) ? lines[currentLine].words.lowerBound : 0
                withCountdown { [weak self] in
                    guard let self else { return }
                    self.voice.start(from: start, localeID: self.speechLocale)
                    self.isPlaying = true
                }
            }
        }
    }

    /// Shows 3, 2, 1 in the prompter before starting, if the countdown is switched on.
    private func withCountdown(_ start: @escaping () -> Void) {
        guard countdownEnabled else { start(); return }
        countdown = 3
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let value = self.countdown else { timer.invalidate(); return }
                if value <= 1 {
                    timer.invalidate()
                    self.countdown = nil
                    start()
                } else {
                    self.countdown = value - 1
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    func setMode(_ newMode: ScrollMode) {
        guard newMode != mode else { return }
        let line = currentLine
        cancelCountdown()
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

    func jump(toSection index: Int) {
        guard sections.indices.contains(index) else { return }
        let word = sections[index].wordIndex
        spokenWordIndex = word
        voice.jump(to: word)
        scroll(toLine: lineIndex(forWord: word))
    }

    func changeSpeed(by delta: Double) {
        speed = min(150, max(5, speed + delta))
    }

    private func voiceAdvanced(to index: Int) {
        spokenWordIndex = index
        scroll(toLine: lineIndex(forWord: index))
    }

    /// Keeps the line being read on the reading row so the previous line stays visible as context.
    private func scroll(toLine line: Int) {
        let target = min(maxOffset, CGFloat(max(0, line - readingRow)) * lineHeight)
        withAnimation(.easeOut(duration: 0.35)) { scrollOffset = target }
    }

    /// Stops everything at once: scrolling, the countdown, the microphone, call-audio capture
    /// and any AI request.
    func hardStop() {
        cancelCountdown()
        isPlaying = false
        voice.stop()
        micActive = false
        micLevel = 0
        if cuesEnabled {
            cueEngine.stop()
            cuesEnabled = false
        }
        cues = []
        cueHeard = ""
        cueStatus = ""
        aiTask?.cancel()
        aiTask = nil
        aiBusy = false
        status = "Stopped. Nothing is listening."
        withAnimation(.easeOut(duration: 0.2)) { showStoppedCard = true }
        stoppedCardTimer?.invalidate()
        stoppedCardTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissStoppedCard() }
        }
    }

    func dismissStoppedCard() {
        stoppedCardTimer?.invalidate()
        stoppedCardTimer = nil
        if showStoppedCard {
            withAnimation(.easeOut(duration: 0.2)) { showStoppedCard = false }
        }
    }

    var isAnythingRunning: Bool { isPlaying || micActive || cuesEnabled || aiBusy || countdown != nil }

    // MARK: Live cues

    func toggleCues() {
        dismissStoppedCard()
        if cuesEnabled {
            cueEngine.stop()
            cuesEnabled = false
            cues = []
            cueHeard = ""
            cueHearing = ""
            cueStatus = ""
        } else {
            // Never start a multi-GB download in the middle of a call.
            if aiEngine == .gemma && !GemmaEngine.isDownloaded {
                cueStatus = "Download Gemma first: Settings → AI engine → Download."
                status = cueStatus
                return
            }
            cuesEnabled = true
            cues = []
            cueHeard = ""
            needsScreenPermission = false
            cueEngine.start(localeID: speechLocale)
        }
    }

    // MARK: AI writer

    func aiWrite(notes: String, tone: String, seconds: Int) {
        startAI(system: Prompts.scriptSystem, prompt: Prompts.writeRequest(notes: notes, tone: tone, seconds: seconds))
    }

    func aiPolish(tone: String) {
        startAI(system: Prompts.scriptSystem, prompt: Prompts.polishRequest(script: script, tone: tone))
    }

    func aiTryAgain() {
        guard let last = lastAIRequest else { return }
        startAI(system: last.system, prompt: last.prompt)
    }

    private func startAI(system: String, prompt: String) {
        lastAIRequest = (system, prompt)
        aiTask?.cancel()
        aiTask = Task { await runAI(system: system, prompt: prompt) }
    }

    /// Puts the reviewed draft into the prompter, keeping the old script for Undo.
    func useDraft() {
        guard let draft = aiDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else { return }
        previousScript = script
        script = draft
        aiDraft = nil
        restart()
        aiMessage = "Your new script is in the prompter."
        editorSectionRequest = .present
    }

    func discardDraft() {
        aiDraft = nil
        aiMessage = nil
    }

    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        aiBusy = false
        aiMessage = "Cancelled."
    }

    private func runAI(system: String, prompt: String) async {
        aiBusy = true
        aiMessage = nil
        defer { aiBusy = false }
        do {
            let text = try await AI.complete(system: system, prompt: prompt, long: true, effort: "medium")
            guard !Task.isCancelled else { return }
            aiDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            aiMessage = nil
        } catch {
            if !Task.isCancelled { aiMessage = error.localizedDescription }
        }
    }

    func prepareGemma() {
        Task {
            do { try await GemmaEngine.shared.prepare() } catch {}
        }
    }

    private func gemmaStatusChanged(_ message: String) {
        gemmaStatus = message
        if let range = message.range(of: #"\d+(?=%)"#, options: .regularExpression), let value = Double(message[range]) {
            gemmaProgress = value / 100
        } else {
            gemmaProgress = message == "Gemma is ready" ? 1 : nil
        }
    }

    func undoAI() {
        guard let previous = previousScript else { return }
        script = previous
        previousScript = nil
        aiMessage = nil
    }

    static let sampleScript = """
    # Welcome
    Welcome to NotchCoach. This text sits right under your camera, so you can read and still look people in the eye.

    # Controls
    Use the buttons under this text to play, pause, skip a line or change the speed. The red Stop button stops everything at once. Every button also has a keyboard shortcut, shown when you hover over it.

    # Sections
    Lines that start with a hash sign, like the headings in this script, become sections. Jump between them with the section buttons, or with Control Option and a number.

    # Voice
    Switch on Follow my voice and the script moves only as you speak. Open the AI writer to turn rough notes into a script you can read aloud.
    """
}
