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
                    params.maxTokens = 16
                    params.temperature = 0.4
                    params.topP = 0.9
                    params.repetitionPenalty = 1.05
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

                            // Ограничиваемся одной строкой
                            if generatedText.contains("\n") {
                                let line = generatedText.components(separatedBy: "\n").first ?? ""
                                return Self.formatSuggestion(line, prompt: trimmedPrompt, maxWords: 4)
                            }

                            // Проверяем количество сгенерированных слов
                            let words = generatedText.split(whereSeparator: { $0.isWhitespace })
                            if words.count >= 4 {
                                return Self.formatSuggestion(generatedText, prompt: trimmedPrompt, maxWords: 4)
                            }

                            // Если предложение завершено пунктуацией
                            if words.count >= 1, tokenText.contains(".") || tokenText.contains("?") || tokenText.contains("!") {
                                return Self.formatSuggestion(generatedText, prompt: trimmedPrompt, maxWords: 4)
                            }
                        default:
                            break
                        }
                    }

                    return Self.formatSuggestion(generatedText, prompt: trimmedPrompt, maxWords: 4)
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

    nonisolated private static func formatSuggestion(_ text: String, prompt: String, maxWords: Int) -> String? {
        var cleaned = text.trimmingCharacters(in: .newlines)

        let promptHasTrailingSpace = prompt.hasSuffix(" ") || prompt.hasSuffix("\t")

        if promptHasTrailingSpace {
            // Пользователь уже нажал пробел после предыдущего слова:
            // Убираем возможный дублирующий начальный пробел из генерации модели
            while cleaned.hasPrefix(" ") {
                cleaned.removeFirst()
            }
        } else {
            // Пользователь печатает слово (пробела в конце промпта нет).
            // Модель должна продолжать текущее слово:
            // Убираем пробелы, чтобы окончание приклеивалось ровно к напечатанной части слова
            while cleaned.hasPrefix(" ") {
                cleaned.removeFirst()
            }
        }

        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }

        // Ограничиваем от 1 до maxWords слов
        let limitedWords = words.prefix(maxWords)
        let joined = limitedWords.joined(separator: " ")

        // Фильтруем численные артефакты (например, "10", "10,", "2022 год")
        if let firstWord = limitedWords.first {
            let stripped = firstWord.trimmingCharacters(in: .punctuationCharacters)
            if !stripped.isEmpty && stripped.allSatisfy({ $0.isNumber }) {
                return nil
            }
        }

        let result = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if Double(result) != nil {
            return nil
        }

        return result.isEmpty ? nil : result
    }
}
