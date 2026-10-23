import AppKit
import ApplicationServices
import Testing
@testable import LocalType

@Suite(.serialized)
@MainActor
struct RegressionTests {
    typealias Harness = CoordinatorIntegrationTests.Harness

    private func makeStore() -> PersonalMemoryStore {
        PersonalMemoryStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalType-\(UUID().uuidString).sqlite3"))
    }

    private func removeStore(_ store: PersonalMemoryStore) {
        store.close()
        try? FileManager.default.removeItem(at: store.databaseURL)
    }

    @Test(arguments: [false, true])
    func acceptancePreservesNewWordBoundary(acceptAll: Bool) async {
        let harness = Harness()
        harness.setSnapshot(beforeCaret: "Thank")
        harness.nextGeneratedSuggestion = " you for your help"
        await harness.coordinator.triggerSuggestion()
        let accepted = acceptAll
            ? harness.coordinator.acceptFullSuggestion()
            : harness.coordinator.acceptNextWord()
        #expect(accepted)
        #expect(harness.snapshot?.beforeCaret == (acceptAll ? "Thank you for your help" : "Thank you"))
    }

    @Test
    func memoryAcceptancePreservesNewWordBoundary() async {
        let store = makeStore()
        defer { removeStore(store) }
        store.recordPhrase("Thank you for your help")
        let harness = Harness(memoryStore: store)
        harness.setSnapshot(beforeCaret: "Thank")
        await harness.coordinator.triggerSuggestion()
        #expect(harness.generatedPrompts.isEmpty)
        #expect(harness.coordinator.acceptNextWord())
        #expect(harness.snapshot?.beforeCaret == "Thank you")
    }

    @Test
    func selectionChangeRejectsOldSuggestion() async throws {
        let harness = Harness()
        harness.setSnapshot(beforeCaret: "Hello ", afterCaret: "existing text")
        await harness.coordinator.triggerSuggestion()
        let snapshot = try #require(harness.snapshot)
        harness.snapshot = TextSnapshot(
            element: snapshot.element, appName: snapshot.appName, bundleID: snapshot.bundleID,
            beforeCaret: snapshot.beforeCaret, afterCaret: "",
            selectedRange: CFRange(location: 6, length: 13),
            caretRectAX: snapshot.caretRectAX, caretRectCocoa: snapshot.caretRectCocoa
        )
        #expect(!harness.coordinator.acceptNextWord())
        #expect(harness.insertedTexts.isEmpty)
        await harness.coordinator.triggerSuggestion()
        #expect(!harness.visible)
        #expect(harness.generatedPrompts.count == 1)
    }

    @Test
    func disablingDuringGenerationDiscardsResult() async {
        let harness = Harness()
        harness.setSnapshot(beforeCaret: "Hello ")
        harness.generationDelayNanoseconds = 40_000_000
        let task = Task { await harness.coordinator.triggerSuggestion() }
        while harness.generatedPrompts.isEmpty { await Task.yield() }
        harness.coordinator.setEnabled(false)
        await task.value
        #expect(!harness.visible)
        #expect(harness.coordinator.active == nil)
    }

    @Test
    func failedFullInsertionPassesTabThrough() async {
        let harness = Harness()
        harness.setSnapshot(beforeCaret: "Hello ")
        harness.insertResult = false
        await harness.coordinator.triggerSuggestion()
        #expect(!harness.coordinator.acceptFullSuggestion())
        #expect(!harness.visible)
    }

    @Test
    func delayedCaretUpdateCannotRestoreOldRemainder() async throws {
        let harness = Harness()
        harness.setSnapshot(beforeCaret: "Hello ")
        harness.nextGeneratedSuggestion = "world today"
        await harness.coordinator.triggerSuggestion()
        #expect(harness.coordinator.acceptNextWord())
        harness.setSnapshot(beforeCaret: "Different ")
        harness.nextGeneratedSuggestion = "suggestion"
        await harness.coordinator.triggerSuggestion()
        try await Task.sleep(for: .milliseconds(90))
        #expect(harness.overlayText == "suggestion")
    }

    @Test
    func clipboardFailureRestoresOriginal() {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = AXAdapter.shared
        let originalPost = adapter.postKeyboardPaste
        defer {
            adapter.postKeyboardPaste = originalPost
            pasteboard.releaseGlobally()
        }
        pasteboard.setString("Original", forType: .string)
        adapter.postKeyboardPaste = { false }
        #expect(!adapter.insertViaTransientClipboard("Suggestion", pasteboard: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Original")
    }

    @Test
    func overlappingPastesRestoreOriginalClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = AXAdapter.shared
        let originalPost = adapter.postKeyboardPaste
        defer {
            adapter.postKeyboardPaste = originalPost
            pasteboard.releaseGlobally()
        }
        pasteboard.setString("Original", forType: .string)
        adapter.postKeyboardPaste = { true }
        #expect(adapter.insertViaTransientClipboard("First", pasteboard: pasteboard, restoreDelay: 0.04))
        #expect(adapter.insertViaTransientClipboard("Second", pasteboard: pasteboard, restoreDelay: 0.08))
        try await Task.sleep(for: .milliseconds(130))
        #expect(pasteboard.string(forType: .string) == "Original")
    }

    @Test
    func newOverlaySurvivesPreviousDismissal() async throws {
        let overlay = OverlayController.shared
        defer { overlay.hide() }
        let caret = CGRect(x: 300, y: 400, width: 2, height: 18)
        overlay.show(suggestion: "Old", at: caret)
        overlay.hide()
        overlay.show(suggestion: "New", at: caret)
        try await Task.sleep(for: .milliseconds(200))
        #expect(overlay.isVisible)
        #expect(overlay.isPanelVisible)
        #expect(overlay.currentSuggestion == "New")
    }

    @Test
    func memoryPrefixTreatsWildcardsLiterallyAndNormalizesSpaces() {
        let store = makeStore()
        defer { removeStore(store) }
        for index in 0..<8 {
            store.recordPhrase("Tax \(index) unrelated phrase", weight: 20)
        }
        store.recordPhrase("Tax % exact phrase")
        store.recordPhrase("Thank you for helping")
        #expect(store.matchPrefixContinuation(for: "Tax %") == " exact phrase")
        #expect(store.matchPrefixContinuation(for: "Thank   you") == " for helping")
    }

    @Test
    func invalidSelectionRangesAreRejected() {
        #expect(AXAdapter.sliceText("Hello", selectedRange: CFRange(location: 3, length: 9)) == nil)
        #expect(AXAdapter.sliceText("Hello", selectedRange: CFRange(location: 3, length: Int.max)) == nil)
    }

    @Test
    func modelCancellationReturnsNil() async throws {
        let service = InferenceService()
        try await service.loadModel()
        let task = Task { await service.generateSuggestion(for: "Thank you for ", maxTokens: 100) }
        for _ in 0..<1000 {
            if service.hasActiveGeneration { break }
            await Task.yield()
        }
        #expect(service.hasActiveGeneration)
        service.cancelCurrentGeneration()
        let result = await task.value
        #expect(result == nil)
        #expect(!service.hasActiveGeneration)
        let next = await service.generateSuggestion(for: "The quick brown fox ")
        #expect(next != nil)
    }
}
