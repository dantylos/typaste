import XCTest
@testable import LocalType

/// Интеграционные проверки реальной модели Qwen3-1.7B-Instruct 4-bit на Metal (≈1 с загрузка).
@MainActor
final class InferenceIntegrationTests: XCTestCase {
    private static var service: InferenceService?

    private func loadedService() async throws -> InferenceService {
        if let s = Self.service { return s }
        let dir = InferenceService.resolveModelDirectory()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path),
            "Модель не найдена: \(dir.path)")
        let s = InferenceService()
        try await s.loadModel()
        Self.service = s
        return s
    }

    func testModelPathResolvesIndependentOfCwd() {
        let dir = InferenceService.resolveModelDirectory()
        XCTAssertTrue(dir.path.hasSuffix("Models/Qwen3-1.7B-mlx-4Bit"), "Ожидалась новая модель Qwen3-1.7B-mlx-4Bit, получено: \(dir.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path), dir.path)
    }

    func testProducesSuggestionsAndLatency() async throws {
        let s = try await loadedService()
        let prompts = [
            "Hello, how are you do",
            "Привет, как дела? Что ты дел",
            "Dear Mr. Smith, I am writing to ",
            "The quick brown fox ",
            "func fetchUser(id: Int) async throws -> ",
        ]
        var latencies: [Double] = []
        var produced = 0
        for p in prompts {
            let t0 = Date()
            let r = await s.generateSuggestion(for: p, maxTokens: 20)
            let ms = Date().timeIntervalSince(t0) * 1000
            latencies.append(ms)
            if let r {
                produced += 1
                XCTAssertFalse(r.contains("\n"))
                XCTAssertFalse(r.contains("<think>"))
                XCTAssertFalse(r.contains("</think>"))
                XCTAssertLessThanOrEqual(r.split(separator: " ").count, 4)
            }
            print("PROBE \(String(format: "%5.0f", ms)) ms | \(p.debugDescription) -> \(String(describing: r).debugDescription)")
        }
        XCTAssertGreaterThanOrEqual(produced, 3, "модель должна выдавать подсказки хотя бы на 3 из 5 промптов")
        let sorted = latencies.sorted()
        print("PROBE latency median=\(sorted[sorted.count / 2]) ms max=\(sorted.last!) ms")
        XCTAssertLessThan(sorted[sorted.count / 2], 800, "медианная латентность > 800 мс")
    }

    func testStyleExamplesAdaptContinuationInRussianAndEnglish() async throws {
        let s = try await loadedService()

        // Проверяем генерацию на русском с примерами стиля пользователя из SQLite
        let ruSuggestion = await s.generateSuggestion(
            for: "Привет! Подскажи, пожалуйста, во сколько ",
            styleExamples: [
                "Подскажи, пожалуйста, во сколько сегодня созвон по проекту?",
                "Давай встретимся после обеда в Зуме."
            ],
            maxTokens: 20
        )
        XCTAssertNotNil(ruSuggestion)
        if let ruSuggestion {
            XCTAssertFalse(ruSuggestion.isEmpty)
            XCTAssertFalse(ruSuggestion.contains("<think>"))
        }

        // Проверяем генерацию на английском с примерами стиля пользователя
        let enSuggestion = await s.generateSuggestion(
            for: "Hi team, please review ",
            styleExamples: [
                "Hi team, please review the pull request before standup.",
                "Thanks for the update on the release branch."
            ],
            maxTokens: 20
        )
        XCTAssertNotNil(enSuggestion)
        if let enSuggestion {
            XCTAssertFalse(enSuggestion.isEmpty)
            XCTAssertFalse(enSuggestion.contains("<think>"))
        }
    }

    func testCancellationReturnsNil() async throws {
        let s = try await loadedService()
        let task = Task {
            await s.generateSuggestion(for: "Once upon a time there was a ", maxTokens: 20)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "A cancelled caller must not receive a suggestion")
    }

    func testMidWordSuggestionsHaveNoTrailingWhitespace() async throws {
        let s = try await loadedService()
        // Если подсказка начинается не с пробела на законченном слове, это дописывание — проверяем только инвариант формата.
        for p in ["Hello", "Thank", "Привет", "Спас"] {
            if let r = await s.generateSuggestion(for: p, maxTokens: 20) {
                XCTAssertFalse(r.hasSuffix(" "))
                print("PROBE midword \(p.debugDescription) -> \(r.debugDescription)")
            }
        }
    }

    func testBackToBackGenerationsSupersedeCleanly() async throws {
        let s = try await loadedService()
        // Запускаем несколько перекрывающихся запросов подряд, проверяя, что финальный запрос завершается корректно
        async let first = s.generateSuggestion(for: "The weather today is ", maxTokens: 20)
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second = s.generateSuggestion(for: "In software engineering, integration testing is ", maxTokens: 20)
        _ = await first
        let finalResult = await second
        XCTAssertNotNil(finalResult)
        if let finalResult {
            XCTAssertFalse(finalResult.contains("\n"))
            XCTAssertLessThanOrEqual(finalResult.split(separator: " ").count, 4)
        }
    }

    func testLongPromptTruncationEndToEnd() async throws {
        let s = try await loadedService()
        // Промпт > 2048 символов проверяет обрезку SuggestionText.trimPrompt по границе слова + токенизацию + генерацию на Metal
        let repeatedParagraph = String(
            repeating: "Локальная модель автодополнения текста работает на Apple Silicon через Metal и ускоряет набор сообщений. ",
            count: 30
        )
        let longPrompt = repeatedParagraph + "Поэтому сегодня мы проверяем как система продолжает"
        XCTAssertGreaterThan(longPrompt.count, 2500)

        let suggestion = await s.generateSuggestion(for: longPrompt, maxTokens: 20)
        XCTAssertNotNil(suggestion)
        if let suggestion {
            XCTAssertFalse(suggestion.isEmpty)
            XCTAssertFalse(suggestion.contains("\n"))
            XCTAssertLessThanOrEqual(suggestion.split(separator: " ").count, 4)
        }
    }
}
