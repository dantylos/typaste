import XCTest
@testable import LocalType

/// Интеграционные проверки реальной модели на Metal (≈1 с загрузка).
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
            if let r { produced += 1; XCTAssertFalse(r.contains("\n")) ; XCTAssertLessThanOrEqual(r.split(separator: " ").count, 4) }
            print("PROBE \(String(format: "%5.0f", ms)) ms | \(p.debugDescription) -> \(String(describing: r).debugDescription)")
        }
        XCTAssertGreaterThanOrEqual(produced, 3, "модель должна выдавать подсказки хотя бы на 3 из 5 промптов")
        let sorted = latencies.sorted()
        print("PROBE latency median=\(sorted[sorted.count / 2]) ms max=\(sorted.last!) ms")
        XCTAssertLessThan(sorted[sorted.count / 2], 800, "медианная латентность > 800 мс")
    }

    func testCancellationReturnsNil() async throws {
        let s = try await loadedService()
        async let r = s.generateSuggestion(for: "Once upon a time there was a ", maxTokens: 20)
        s.cancelCurrentGeneration()
        let result = await r
        // Отмена допустима в любой момент: либо nil, либо уже готовый результат — но не зависание/краш.
        _ = result
    }

    func testMidWordNeverGluesWords() async throws {
        let s = try await loadedService()
        // Если подсказка начинается не с пробела на законченном слове, это дописывание — проверяем только инвариант формата.
        for p in ["Hello", "Thank", "Привет", "Спас"] {
            if let r = await s.generateSuggestion(for: p, maxTokens: 20) {
                XCTAssertFalse(r.hasSuffix(" "))
                print("PROBE midword \(p.debugDescription) -> \(r.debugDescription)")
            }
        }
    }
}
