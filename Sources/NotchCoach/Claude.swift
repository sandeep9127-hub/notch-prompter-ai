import Foundation
import Security

enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refused
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Anthropic API key in Settings first."
        case .http(let code, let message): return "Claude API error \(code): \(message)"
        case .refused: return "Claude declined this request."
        case .empty: return "Claude returned no text."
        }
    }
}

enum ClaudeClient {
    static let defaultModel = "claude-opus-5-5"
    static let models: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (best quality)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (faster, cheaper)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (fastest, cheapest)"),
    ]
    /// Models that accept server-side refusal fallbacks.
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5"]

    static var model: String {
        UserDefaults.standard.string(forKey: "model") ?? defaultModel
    }

    static func complete(system: String, prompt: String, maxTokens: Int, effort: String) async throws -> String {
        guard let key = Keychain.apiKey, !key.isEmpty else { throw ClaudeError.missingKey }
        let model = self.model

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": effort],
        ]
        if fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.http(status, message)
        }
        if json["stop_reason"] as? String == "refusal" { throw ClaudeError.refused }

        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeError.empty }
        return text
    }
}

enum Keychain {
    private static let service = "NotchCoach"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

enum Prompts {
    static let scriptSystem = """
    You write scripts that one person will read aloud from a teleprompter during a video call, presentation or recording.
    - Write only the words to be spoken: no headings, bullet points, stage directions, emojis or markdown.
    - Use short, natural sentences that are easy to say out loud. Put one idea in each paragraph, with a blank line between paragraphs.
    - Keep the speaker's own facts, names and numbers. Never invent facts, statistics, quotes or commitments.
    - Write in the same language as the material you are given.
    Reply with the script only.
    """

    static func writeRequest(notes: String, tone: String, seconds: Int) -> String {
        let words = max(40, seconds * 140 / 60)
        let length = seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute\(seconds >= 120 ? "s" : "")"
        return """
        Turn these notes into a \(tone.lowercased()) spoken script of about \(words) words (roughly \(length) when read aloud).

        <notes>
        \(notes)
        </notes>
        """
    }

    static func polishRequest(script: String, tone: String) -> String {
        """
        Polish this script so it sounds \(tone.lowercased()) and natural when read aloud. Keep its length, meaning and every fact. Fix awkward phrasing and split long sentences.

        <script>
        \(script)
        </script>
        """
    }

    static let cueSystem = """
    You are a discreet coach for someone on a live video call. You get a rough automatic transcript of what the other people just said (it can contain recognition errors) and the user's own notes. Suggest what the user could say next.
    - Give at most 3 cues, one per line, each under 10 words. No numbering, bullets or quotation marks.
    - If someone just asked a question, make the first cue a direct answer.
    - Base cues on the user's notes where you can. Never invent facts, figures or commitments.
    - If there is nothing useful to suggest, reply with exactly: NONE
    """

    static func cueRequest(notes: String, transcript: String) -> String {
        """
        <user_notes>
        \(notes.prefix(3000))
        </user_notes>

        <recent_transcript_of_other_people>
        \(transcript)
        </recent_transcript_of_other_people>
        """
    }

    static func parseCues(_ text: String) -> [String] {
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                line.replacingOccurrences(of: #"^\s*(?:[-•*›>]|\d+[.)])\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”")))
            }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" }
        return Array(cleaned.prefix(3))
    }
}
