import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIEngineKind: String, CaseIterable, Identifiable {
    case gemma, claude, apple
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gemma: return "Gemma (on this Mac, free)"
        case .claude: return "Claude (your API key)"
        case .apple: return "Apple Intelligence (on this Mac, free)"
        }
    }
}

enum AIError: LocalizedError {
    case appleUnavailable(String)
    case tooLong

    var errorDescription: String? {
        switch self {
        case .appleUnavailable(let reason): return reason
        case .tooLong: return "That's too much text for Apple Intelligence. Try a shorter script, or switch to Gemma or Claude in Settings."
        }
    }
}

/// Routes every AI request to the engine chosen in Settings.
enum AI {
    static var engine: AIEngineKind {
        AIEngineKind(rawValue: UserDefaults.standard.string(forKey: "aiEngine") ?? "") ?? .gemma
    }

    /// `effort` only applies to Claude; `long` asks for room to write a full script.
    static func complete(system: String, prompt: String, long: Bool, effort: String) async throws -> String {
        let text: String
        switch engine {
        case .claude:
            text = try await ClaudeClient.complete(system: system, prompt: prompt, maxTokens: long ? 16000 : 2000, effort: effort)
        case .gemma:
            text = try await GemmaEngine.shared.complete(system: system, prompt: prompt, maxTokens: long ? 3000 : 200)
        case .apple:
            text = try await AppleEngine.complete(system: system, prompt: prompt)
        }
        return clean(text)
    }

    /// Small local models sometimes leave chat-template tags in their output.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|?[a-z_]+\|?>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Gemma via MLX

enum GemmaModel: String, CaseIterable, Identifiable {
    case e2b, e4b
    var id: String { rawValue }

    var label: String {
        switch self {
        case .e2b: return "Gemma 4 E2B (smaller, faster)"
        case .e4b: return "Gemma 4 E4B (better writing, needs more memory)"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .e2b: return LLMRegistry.gemma4_e2b_it_4bit
        case .e4b: return LLMRegistry.gemma4_e4b_it_4bit
        }
    }

    static var selected: GemmaModel {
        GemmaModel(rawValue: UserDefaults.standard.string(forKey: "gemmaModel") ?? "") ?? .e2b
    }
}

/// Loads Gemma once (downloading it from Hugging Face the first time) and keeps it in memory.
actor GemmaEngine {
    static let shared = GemmaEngine()

    /// Called with human-readable progress such as "Downloading Gemma… 42%".
    nonisolated(unsafe) var onStatus: ((String) -> Void)?

    private var container: ModelContainer?
    private var loadedModel: GemmaModel?
    private var loading: Task<ModelContainer, Error>?

    func prepare() async throws {
        _ = try await load()
    }

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let model = try await load()
        let session = ChatSession(
            model,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.6)
        )
        return try await session.respond(to: prompt)
    }

    private func load() async throws -> ModelContainer {
        let wanted = GemmaModel.selected
        if let container, loadedModel == wanted { return container }
        if let loading { return try await loading.value }

        container = nil
        let status = onStatus
        let task = Task { () throws -> ModelContainer in
            status?("Loading Gemma…")
            let result = try await #huggingFaceLoadModelContainer(
                configuration: wanted.configuration,
                progressHandler: { progress in
                    let percent = Int(progress.fractionCompleted * 100)
                    if percent < 100 { status?("Downloading Gemma… \(percent)%") }
                }
            )
            status?("Gemma is ready")
            return result
        }
        loading = task
        defer { loading = nil }
        do {
            let result = try await task.value
            container = result
            loadedModel = wanted
            UserDefaults.standard.set(true, forKey: "gemmaReady-\(wanted.rawValue)")
            return result
        } catch {
            status?("Couldn't load Gemma: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Apple Intelligence

enum AppleEngine {
    /// nil when the on-device Apple model can be used, otherwise the reason it can't.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading. Try again in a few minutes."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }

    static func complete(system: String, prompt: String) async throws -> String {
        if let reason = unavailableReason { throw AIError.appleUnavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: system)
            do {
                return try await session.respond(to: prompt).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                throw AIError.tooLong
            }
        }
        #endif
        throw AIError.appleUnavailable("Apple Intelligence needs macOS 26 or later.")
    }
}
