import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Tokenizer Adapter (swift-transformers -> MLXLMCommon)

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct LocalTransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

// MARK: - InferenceService

@MainActor
public final class InferenceService {
    private var container: ModelContainer?
    private var currentTask: Task<String?, Never>?
    private let modelDirectory: URL
    public private(set) var isReady: Bool = false

    public init(modelDirectory: URL = URL(fileURLWithPath: "Models/Qwen3-1.7B-Base-mlx-4Bit")) {
        self.modelDirectory = modelDirectory
    }

    public func loadModel() async throws {
        guard container == nil else { return }
        let start = Date()
        NSLog("[InferenceService] Loading model from: %@", modelDirectory.path)
        let loaded = try await loadModelContainer(
            from: modelDirectory,
            using: LocalTransformersTokenizerLoader()
        )
        self.container = loaded
        self.isReady = true
        let elapsed = Date().timeIntervalSince(start)
        NSLog("[InferenceService] Model loaded successfully in %.2fs", elapsed)
    }

    public func generateSuggestion(for prompt: String, maxTokens: Int = 20) async -> String? {
        guard let container, isReady else {
            NSLog("[InferenceService] Model container is not ready")
            return nil
        }

        // Отменяем любую незавершенную генерацию
        currentTask?.cancel()

        let task = Task<String?, Never> { [container] () -> String? in
            guard !Task.isCancelled else { return nil }

            do {
                return try await container.perform { context -> String? in
                    guard !Task.isCancelled else { return nil }

                    // Ограничиваем длину промпта последними ~2048 символами
                    let trimmedPrompt = prompt.count > 2048
                        ? String(prompt.suffix(2048))
                        : prompt

                    guard !trimmedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }

                    let promptTokens = context.tokenizer.encode(text: trimmedPrompt, addSpecialTokens: false)
                    guard !promptTokens.isEmpty, !Task.isCancelled else { return nil }

                    let input = LMInput(tokens: MLXArray(promptTokens))
                    var params = GenerateParameters()
                    params.maxTokens = maxTokens
                    params.temperature = 0.0 // Детерминированная базовая генерация per SPEC §9
                    params.repetitionPenalty = 1.1
                    params.repetitionContextSize = 64

                    let stream = try generate(
                        input: input,
                        parameters: params,
                        context: context
                    )

                    var generatedText = ""

                    for await item in stream {
                        if Task.isCancelled { return nil }

                        switch item {
                        case .chunk(let tokenText):
                            generatedText += tokenText

                            // Ограничиваемся одной фразой / строкой для чистой автоподстановки
                            if generatedText.contains("\n") {
                                let lines = generatedText.components(separatedBy: "\n")
                                return lines.first?.trimmingCharacters(in: .whitespaces)
                            }

                            // Если предложение логически завершено точкой, знаком вопроса или восклицания
                            if generatedText.count >= 8,
                               tokenText.contains(".") || tokenText.contains("?") || tokenText.contains("!") {
                                return generatedText
                            }
                        default:
                            break
                        }
                    }

                    let cleaned = generatedText.trimmingCharacters(in: .newlines)
                    return cleaned.isEmpty ? nil : cleaned
                }
            } catch {
                if !Task.isCancelled {
                    NSLog("[InferenceService] Error during generation: %@", error.localizedDescription)
                }
                return nil
            }
        }

        currentTask = task
        return await task.value
    }

    public func cancelCurrentGeneration() {
        currentTask?.cancel()
        currentTask = nil
    }
}
