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

// MARK: - Step 0.1 & 0.2 Spike Runner

print("=== LocalType ModelSpike: Qwen3-1.7B-Base 4-bit ===")

let modelDir = URL(fileURLWithPath: "Models/Qwen3-1.7B-Base-mlx-4Bit")
guard FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("model.safetensors").path) else {
    print("ERROR: model.safetensors not found in \(modelDir.path)")
    exit(1)
}

print("1. Loading model container from local directory...")
let startLoad = Date()
let container: ModelContainer
do {
    container = try await loadModelContainer(
        from: modelDir,
        using: LocalTransformersTokenizerLoader()
    )
} catch {
    print("ERROR loading model container: \(error)")
    exit(1)
}
let loadTime = Date().timeIntervalSince(startLoad)
print("Model loaded successfully in \(String(format: "%.2f", loadTime))s")

// Test prompts for Step 0.2: Causal continuation vs Priming
let prompts = [
    "Как дела? ",
    "Переписка:\n— Привет! Как дела? ",
    "Чат друзей:\n— Привет! Как дела? ",
    "Диалог:\n— Привет!\n— Привет, как дела?\n— Нормально, а у тебя?\n— Тоже хорошо. Как дела? ",
    "Я пишу сообщение коллеге: Как дела? "
]

for (index, prompt) in prompts.enumerated() {
    print("\n--------------------------------------------------")
    print("Test [\(index + 1)/\(prompts.count)] Prompt: \"\(prompt)\"")
    
    do {
        try await container.perform { context in
            let promptTokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            print("Prompt token IDs: \(promptTokens)")
            
            let input = LMInput(tokens: MLXArray(promptTokens))
            var params = GenerateParameters()
            params.maxTokens = 15
            params.temperature = 0.6
            params.topP = 0.9
            params.repetitionPenalty = 1.0
            
            let startGen = Date()
            var firstTokenTime: TimeInterval?
            var generatedTokens = 0
            var generatedText = ""
            
            let stream = try generate(
                input: input,
                parameters: params,
                context: context
            )
            
            for await item in stream {
                switch item {
                case .chunk(let text):
                    if firstTokenTime == nil {
                        firstTokenTime = Date().timeIntervalSince(startGen)
                    }
                    generatedTokens += 1
                    generatedText += text
                    print(text, terminator: "")
                    fflush(stdout)
                    
                    if text.contains("\n") {
                        break
                    }
                case .info(let info):
                    let totalTime = Date().timeIntervalSince(startGen)
                    print("\n\nStats:")
                    if let ttft = firstTokenTime {
                        print("- TTFT (Time to first token): \(String(format: "%.1f", ttft * 1000)) ms")
                    }
                    print("- Total generation time: \(String(format: "%.2f", totalTime)) s")
                    print("- Generation speed: \(String(format: "%.1f", info.tokensPerSecond)) tokens/s")
                default:
                    break
                }
            }
        }
    } catch {
        print("Error during generation: \(error)")
    }
}

print("\n==================================================")
print("ModelSpike verification complete.")
