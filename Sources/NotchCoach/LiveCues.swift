import AVFoundation
import ScreenCaptureKit
import Speech

/// Captures the Mac's system audio (the other people on a call), transcribes it on-device,
/// and after each pause asks Claude for short talking points. Public methods run on main.
final class LiveCueEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onCues: (([String]) -> Void)?
    var onStatus: ((String) -> Void)?
    var contextProvider: (() -> String)?
    private(set) var isRunning = false

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "notchcoach.system-audio")
    private let box = RequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var pauseTimer: Timer?

    private var history = ""
    private var partial = ""
    private var lastChange = Date()
    private var sentUpTo = 0
    private var requesting = false

    private static let listening = "Listening to call audio…"

    func start(localeID: String) {
        guard !isRunning else { return }
        Permissions.requestSpeech { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.onStatus?("Allow Speech Recognition for NotchCoach in System Settings → Privacy & Security.")
                return
            }
            self.begin(localeID: localeID)
        }
    }

    private func begin(localeID: String) {
        guard let rec = Permissions.recognizer(for: localeID) else {
            onStatus?("Speech recognition isn't available for \(localeID).")
            return
        }
        recognizer = rec
        isRunning = true
        history = ""
        partial = ""
        sentUpTo = 0
        onStatus?("Starting system audio capture…")
        startTask()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForPause()
        }
        Task { await self.startCapture() }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw NSError(domain: "NotchCoach", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 1
            // Video is required by ScreenCaptureKit but unused; keep it tiny and slow.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()
            DispatchQueue.main.async {
                if self.isRunning {
                    self.stream = newStream
                    self.onStatus?(Self.listening)
                } else {
                    newStream.stopCapture { _ in }
                }
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
                self.stop()
                self.onStatus?("Couldn't capture call audio. Allow NotchCoach under System Settings → Privacy & Security → Screen & System Audio Recording, then turn cues on again. (\(message))")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = AudioConvert.pcmBuffer(from: sampleBuffer) else { return }
        box.append(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.stop()
            self.onStatus?("Call audio capture stopped: \(message)")
        }
    }

    private func startTask() {
        guard isRunning, let rec = recognizer else { return }
        task?.cancel()
        generation += 1
        let gen = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        box.set(request)
        task = rec.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let finished = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async {
                guard let self, self.isRunning, gen == self.generation else { return }
                if text != self.partial {
                    self.partial = text
                    self.lastChange = Date()
                }
                if finished {
                    if !self.partial.isEmpty { self.history += self.partial + " " }
                    self.partial = ""
                    if self.history.count > 6000 {
                        let drop = self.history.count - 4000
                        self.history = String(self.history.dropFirst(drop))
                        self.sentUpTo = max(0, self.sentUpTo - drop)
                    }
                    self.generation += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.startTask() }
                }
            }
        }
    }

    /// Asks for cues once the other side has said something new and then paused.
    private func checkForPause() {
        guard isRunning, !requesting else { return }
        let transcript = history + partial
        guard transcript.count - sentUpTo > 25, Date().timeIntervalSince(lastChange) > 1.5 else { return }
        sentUpTo = transcript.count
        requesting = true
        let recent = String(transcript.suffix(1500))
        let context = contextProvider?() ?? ""
        onStatus?("Thinking…")
        Task {
            do {
                let reply = try await ClaudeClient.complete(
                    system: Prompts.cueSystem,
                    prompt: Prompts.cueRequest(notes: context, transcript: recent),
                    maxTokens: 2000,
                    effort: "low"
                )
                let cues = Prompts.parseCues(reply)
                DispatchQueue.main.async {
                    self.requesting = false
                    guard self.isRunning else { return }
                    if !cues.isEmpty { self.onCues?(cues) }
                    self.onStatus?(Self.listening)
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.requesting = false
                    guard self.isRunning else { return }
                    self.onStatus?(message)
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        pauseTimer?.invalidate()
        pauseTimer = nil
        task?.cancel()
        task = nil
        box.set(nil)
        if let current = stream {
            stream = nil
            current.stopCapture { _ in }
        }
        onStatus?("")
    }
}
