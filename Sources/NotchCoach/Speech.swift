import AppKit
import AVFoundation
import CoreMedia
import Speech

/// Thread-safe holder for the current recognition request, fed from audio threads.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = newRequest
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }
}

/// Turns microphone buffers into a 0–1 loudness value, reported at most 20 times a second.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = 0.0
    private let report: (Float) -> Void

    init(report: @escaping (Float) -> Void) {
        self.report = report
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = now - lastReport >= 0.05
        if due { lastReport = now }
        lock.unlock()
        guard due, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        // Map roughly -50 dB…0 dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { self.report(level) }
    }
}

enum Permissions {
    static func requestSpeech(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let speechSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!

    static var speechStatusName: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    static var microphoneStatusName: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    /// Clears a stale Screen & System Audio Recording entry, for example one left by an older
    /// build, so macOS asks again cleanly.
    static func resetScreenRecording() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "app.notchcoach.NotchCoach"]
        try? task.run()
        task.waitUntilExit()
        Log.write("Reset Screen Recording permission (exit \(task.terminationStatus))")
    }

    /// macOS applies a new Screen Recording grant only after the app restarts.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func recognizer(for localeID: String) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer()
    }
}

enum TextMatch {
    static func normalize(_ word: String) -> String {
        let scalars = word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        if a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        if a.count >= 5 && b.count >= 5 && abs(a.count - b.count) <= 1 { return editDistance(a, b) <= 1 }
        return false
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[y.count]
    }
}

/// Listens to the microphone with Apple's speech recognizer and reports how far into the
/// script the speaker has got. All public methods are called on the main thread.
final class VoiceFollower {
    var onWordIndex: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// The latest words recognised from your microphone.
    var onHearing: ((String) -> Void)?
    /// Called with a System Settings page when a permission is missing.
    var onPermissionProblem: ((URL) -> Void)?
    private(set) var isRunning = false
    private(set) var microphoneName = ""

    private let engine = AVAudioEngine()
    private lazy var meter = LevelMeter { [weak self] level in
        self?.levelReceived(level)
        self?.onLevel?(level)
    }
    private var peakLevel: Float = 0
    private var silenceCheck: DispatchWorkItem?
    private var loggedFirstWords = false
    private var misses = 0
    private let box = RequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var tokens: [String] = []
    private var position = 0
    private var generation = 0
    private var backoff = RecognitionBackoff()

    func update(words: [String]) {
        tokens = words.map(TextMatch.normalize)
        position = min(position, tokens.count)
    }

    func jump(to index: Int) {
        position = max(0, min(index, tokens.count))
    }

    func start(from index: Int, localeID: String) {
        guard !isRunning else { return }
        position = index
        Log.write("Voice: start requested (speech: \(Permissions.speechStatusName), microphone: \(Permissions.microphoneStatusName), language: \(localeID))")
        onStatus?("Checking permissions…")
        Permissions.requestSpeech { [weak self] speechOK in
            guard let self else { return }
            Log.write("Voice: speech recognition \(speechOK ? "allowed" : "not allowed") (\(Permissions.speechStatusName))")
            guard speechOK else {
                self.onPermissionProblem?(Permissions.speechSettings)
                self.onStatus?("Speech Recognition is off for NotchCoach. Turn it on in System Settings → Privacy & Security → Speech Recognition, then try again.")
                return
            }
            Permissions.requestMicrophone { micOK in
                Log.write("Voice: microphone \(micOK ? "allowed" : "not allowed") (\(Permissions.microphoneStatusName))")
                guard micOK else {
                    self.onPermissionProblem?(Permissions.microphoneSettings)
                    self.onStatus?("Microphone is off for NotchCoach. Turn it on in System Settings → Privacy & Security → Microphone, then try again.")
                    return
                }
                self.begin(localeID: localeID)
            }
        }
    }

    /// Notices a microphone that's on but sending silence (wrong input device, or blocked).
    private func levelReceived(_ level: Float) {
        guard isRunning else { return }
        if peakLevel < 0.15 && level >= 0.15 { Log.write("Voice: hearing sound from the microphone") }
        peakLevel = max(peakLevel, level)
    }

    private func begin(localeID: String) {
        guard let rec = Permissions.recognizer(for: localeID), rec.isAvailable else {
            Log.write("Voice: recogniser unavailable for \(localeID)")
            onStatus?("Speech recognition isn't available for \(localeID) right now. Try English (US) in Settings → Speech, and check that Dictation is on in System Settings → Keyboard.")
            return
        }
        recognizer = rec
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        microphoneName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown microphone"
        Log.write("Voice: input \(microphoneName), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, on-device: \(rec.supportsOnDeviceRecognition)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onStatus?("No microphone input found. Pick a microphone in System Settings → Sound → Input.")
            return
        }
        input.removeTap(onBus: 0)
        let box = self.box
        let meter = self.meter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
            meter.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onStatus?("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        isRunning = true
        peakLevel = 0
        loggedFirstWords = false
        misses = 0
        onStatus?("Listening with \(microphoneName)\(rec.supportsOnDeviceRecognition ? " (on-device)" : "")")
        startTask()

        silenceCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.peakLevel < 0.08 else { return }
            Log.write("Voice: microphone looks silent after 6 seconds (peak \(self.peakLevel))")
            self.onPermissionProblem?(Permissions.microphoneSettings)
            self.onStatus?("“\(self.microphoneName)” isn't picking up any sound. Check System Settings → Sound → Input, and that NotchCoach is on under Privacy & Security → Microphone.")
        }
        silenceCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: check)
    }

    private func startTask() {
        guard isRunning, let rec = recognizer else { return }
        task?.cancel()
        generation += 1
        let gen = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if rec.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        box.set(request)
        backoff.started()
        task = rec.recognitionTask(with: request) { [weak self] result, error in
            let spoken = result?.bestTranscription.segments.map { $0.substring } ?? []
            let finished = (result?.isFinal ?? false) || error != nil
            let errorText = error.map { error -> String in
                let ns = error as NSError
                return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
            }
            DispatchQueue.main.async {
                guard let self, self.isRunning, gen == self.generation else { return }
                if let errorText { Log.write("Voice: recogniser ended with \(errorText)") }
                if !spoken.isEmpty {
                    if !self.loggedFirstWords {
                        self.loggedFirstWords = true
                        Log.write("Voice: first words recognised")
                    }
                    self.backoff.heardSpeech()
                    self.onHearing?(spoken.suffix(12).joined(separator: " "))
                    self.align(spoken)
                }
                if finished {
                    // Recognition sessions end after silence or a time limit; start a fresh one.
                    self.generation += 1
                    guard let delay = self.backoff.nextDelay() else {
                        Log.write("Voice follow gave up: \(errorText ?? "no error text")")
                        self.stop()
                        self.onStatus?("Speech recognition keeps failing\(errorText.map { ": \($0)" } ?? ""). Check that Dictation is available in System Settings → Keyboard.")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.startTask() }
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        Log.write("Voice: stopped")
        isRunning = false
        silenceCheck?.cancel()
        generation += 1
        task?.cancel()
        task = nil
        box.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        onStatus?("")
    }

    /// Finds where the last few spoken words best line up with the script, searching a window
    /// just behind and ahead of the current position, and moves forward to it.
    private func align(_ spokenRaw: [String]) {
        let spoken = spokenRaw.map(TextMatch.normalize).filter { !$0.isEmpty }
        let tail = Array(spoken.suffix(6))
        guard let last = tail.last, !tokens.isEmpty else { return }
        let low = max(0, position - 2)
        let high = min(tokens.count - 1, position + 25)
        guard low <= high else { return }

        var bestEnd = -1
        var bestScore = 0.0
        for end in low...high {
            let secondLast = tail.count > 1 ? tail[tail.count - 2] : ""
            guard TextMatch.similar(tokens[end], last) || TextMatch.similar(tokens[end], secondLast) else { continue }
            var matches = 0
            var i = tail.count - 1
            var j = end
            while i >= 0 && j >= 0 && end - j < 10 {
                if tokens[j].isEmpty { j -= 1; continue }
                if TextMatch.similar(tail[i], tokens[j]) {
                    matches += 1
                    i -= 1
                    j -= 1
                } else {
                    i -= 1
                }
            }
            let required = end <= position + 1 ? 1 : 2
            guard matches >= required else { continue }
            let score = Double(matches) - Double(abs(end - position)) * 0.05
            if score > bestScore {
                bestScore = score
                bestEnd = end
            }
        }
        if bestEnd < 0 {
            // Nothing nearby matched. After a few misses, look across the whole script in case
            // the reader started somewhere else or skipped ahead.
            misses += 1
            if misses >= 3, tail.count >= 4, let found = searchWholeScript(tail) {
                Log.write("Voice: jumped to word \(found) after losing the place")
                misses = 0
                position = found + 1
                onWordIndex?(position)
            }
            return
        }
        misses = 0
        guard bestEnd + 1 != position else { return }
        position = bestEnd + 1
        onWordIndex?(position)
    }

    /// Finds where the last few spoken words appear in a row anywhere in the script.
    private func searchWholeScript(_ tail: [String]) -> Int? {
        let needed = min(4, tail.count)
        let probe = Array(tail.suffix(needed))
        var best: (end: Int, matches: Int)?
        for end in (needed - 1)..<tokens.count {
            var matches = 0
            for k in 0..<needed where TextMatch.similar(probe[needed - 1 - k], tokens[end - k]) {
                matches += 1
            }
            if matches >= needed - 1, matches > (best?.matches ?? 0) || (matches == best?.matches && abs(end - position) < abs((best?.end ?? 0) - position)) {
                best = (end, matches)
            }
        }
        return best?.end
    }
}

enum AudioConvert {
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
