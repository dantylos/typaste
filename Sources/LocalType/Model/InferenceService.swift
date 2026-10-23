import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ModelSupport

// MARK: - InferenceService

@MainActor
public final class InferenceService {
    private var container: ModelContainer?
    private var currentTask: Task<String?, Never>?
    private var generationID = UUID()
    private var currentTaskID: UUID?
    internal var hasActiveGeneration: Bool { currentTask != nil }
    private let modelDirectory: URL
    public private(set) var isReady: Bool = false

    nonisolated public static let modelFolderName = "Qwen3-1.7B-mlx-4Bit"
    nonisolated public static let legacyModelFolderName = "Qwen3-1.7B-Base-mlx-4Bit"
    nonisolated private static let maxPromptCharacters = 2048
    nonisolated private static let maxSuggestionWords = 4

    public init(modelDirectory: URL = InferenceService.resolveModelDirectory()) {
        self.modelDirectory = modelDirectory
    }

    /// Порядок поиска: $LOCALTYPE_MODEL_DIR → Resources бандла → подъём вверх от исполняемого файла → от cwd.
    nonisolated public static func resolveModelDirectory(sourceFile: String = #filePath) -> URL {
        let fm = FileManager.default
        func isModel(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
                && fm.fileExists(atPath: url.appendingPathComponent("model.safetensors").path)
        }

        if let env = ProcessInfo.processInfo.environment["LOCALTYPE_MODEL_DIR"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if isModel(url) { return url }
        }

        let candidateNames = [modelFolderName, legacyModelFolderName]

        if let res = Bundle.main.resourceURL {
            for name in candidateNames {
                let url = res.appendingPathComponent("Models/\(name)")
                if isModel(url) { return url }
            }
        }

        var starts: [URL] = []
        if let exe = Bundle.main.executableURL { starts.append(exe.deletingLastPathComponent()) }
        starts.append(URL(fileURLWithPath: fm.currentDirectoryPath))
        // Dev/test-хосты (xctest и т.п.): путь исходника, зашитый при компиляции
        starts.append(URL(fileURLWithPath: sourceFile).deletingLastPathComponent())

        for name in candidateNames {
            for start in starts {
                var dir = start
                for _ in 0..<10 {
                    let url = dir.appendingPathComponent("Models/\(name)")
                    if isModel(url) { return url }
                    let parent = dir.deletingLastPathComponent()
                    if parent == dir { break }
                    dir = parent
                }
            }
        }

        // Не найдено: вернём ожидаемый путь — loadModel() выдаст понятную ошибку.
        return URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Models/\(modelFolderName)")
    }

    public func loadModel() async throws {
        guard container == nil else { return }
        guard FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path) else {
            throw NSError(domain: "LocalType", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Модель не найдена: \(modelDirectory.path). Задайте LOCALTYPE_MODEL_DIR."
            ])
        }
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

    public func generateSuggestion(
        for prompt: String,
        styleExamples: [String] = [],
        maxTokens: Int = 20
    ) async -> String? {
        guard let container, isReady else {
            NSLog("[InferenceService] Model container is not ready")
            return nil
        }

        guard !Task.isCancelled else { return nil }
        let requestID = UUID()
        generationID = requestID

        // Отменяем любую незавершенную генерацию и дожидаемся освобождения контейнера
        if let previousTask = currentTask {
            previousTask.cancel()
            _ = await previousTask.value
        }

        guard generationID == requestID, !Task.isCancelled else { return nil }
        let task = Task<String?, Never> { [container] () -> String? in
            guard !Task.isCancelled else { return nil }

            do {
                return try await container.perform { context -> String? in
                    guard !Task.isCancelled else { return nil }

                    // Ограничиваем длину промпта; режем по границе слова, если обрезано начало
                    let trimmedPrompt = SuggestionText.trimPrompt(prompt, limit: Self.maxPromptCharacters)

                    guard !trimmedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }

                    // Формируем вход для Qwen3-1.7B-Instruct с отключенным <think> и примерами пользователя
                    let instructInput = SuggestionText.buildInstructInput(
                        prompt: trimmedPrompt,
                        styleExamples: styleExamples
                    )

                    let promptTokens = context.tokenizer.encode(text: instructInput, addSpecialTokens: false)
                    guard !promptTokens.isEmpty, !Task.isCancelled else { return nil }

                    let input = LMInput(tokens: MLXArray(promptTokens))
                    var params = GenerateParameters()
                    params.maxTokens = maxTokens
                    params.temperature = 0.0
                    params.topP = 1.0
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
                            if tokenText.contains("<|im_end|>") || tokenText.contains("<|endoftext|>") {
                                let cleanToken = tokenText
                                    .replacingOccurrences(of: "<|im_end|>", with: "")
                                    .replacingOccurrences(of: "<|endoftext|>", with: "")
                                generatedText += cleanToken
                                return SuggestionText.format(generatedText, prompt: trimmedPrompt, maxWords: Self.maxSuggestionWords)
                            }

                            generatedText += tokenText

                            // Ограничиваемся одной строкой
                            if generatedText.contains("\n") {
                                let line = generatedText.components(separatedBy: "\n").first ?? ""
                                return SuggestionText.format(line, prompt: trimmedPrompt, maxWords: Self.maxSuggestionWords)
                            }

                            // Проверяем количество сгенерированных слов
                            let words = generatedText.split(whereSeparator: { $0.isWhitespace })
                            if words.count > Self.maxSuggestionWords {
                                return SuggestionText.format(generatedText, prompt: trimmedPrompt, maxWords: Self.maxSuggestionWords)
                            }

                            // Если предложение завершено пунктуацией
                            if words.count >= 1, tokenText.contains(".") || tokenText.contains("?") || tokenText.contains("!") {
                                return SuggestionText.format(generatedText, prompt: trimmedPrompt, maxWords: Self.maxSuggestionWords)
                            }
                        default:
                            break
                        }
                    }

                    return SuggestionText.format(generatedText, prompt: trimmedPrompt, maxWords: Self.maxSuggestionWords)
                }
            } catch {
                if !Task.isCancelled {
                    NSLog("[InferenceService] Error during generation: %@", error.localizedDescription)
                }
                return nil
            }
        }

        currentTask = task
        currentTaskID = requestID
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if currentTaskID == requestID {
            currentTask = nil
            currentTaskID = nil
        }
        guard generationID == requestID else { return nil }
        return Task.isCancelled ? nil : result
    }

    public func cancelCurrentGeneration() {
        generationID = UUID()
        currentTask?.cancel()
        // Keep the task until it finishes so the next request can await cleanup.
    }
}
