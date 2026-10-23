import AppKit
import ApplicationServices
import XCTest
@testable import LocalType

@MainActor
final class CoordinatorIntegrationTests: XCTestCase {

    @MainActor
    final class Harness {
        var snapshot: TextSnapshot?
        var insertedTexts: [String] = []
        var insertResult: Bool = true
        var generatedPrompts: [String] = []
        var nextGeneratedSuggestion: String? = "world today"
        var generationDelayNanoseconds: UInt64 = 0
        var cancelGenerationCount = 0

        var visible = false
        var overlayText: String?
        var overlayCaret: CGRect?
        var hideCount = 0

        var memoryStore: PersonalMemoryStore?
        var coordinator: AssistantCoordinator!

        init(memoryStore: PersonalMemoryStore? = nil) {
            self.memoryStore = memoryStore
            self.coordinator = AssistantCoordinator(
                ownedInferenceService: nil,
                memoryStore: memoryStore,
                debounceInterval: 0.04,
                snapshotProvider: { [weak self] _ in
                    self?.snapshot
                },
                inserter: { [weak self] text, _ in
                    guard let self else { return false }
                    guard self.insertResult else { return false }
                    self.insertedTexts.append(text)
                    if let snap = self.snapshot {
                        let newBefore = snap.beforeCaret + text
                        self.snapshot = TextSnapshot(
                            element: snap.element,
                            appName: snap.appName,
                            bundleID: snap.bundleID,
                            beforeCaret: newBefore,
                            afterCaret: snap.afterCaret,
                            selectedRange: CFRange(location: (newBefore as NSString).length, length: 0),
                            caretRectAX: snap.caretRectAX,
                            caretRectCocoa: snap.caretRectCocoa
                        )
                    }
                    return true
                },
                generateHandler: { [weak self] prompt, _ in
                    guard let self else { return nil }
                    self.generatedPrompts.append(prompt)
                    if self.generationDelayNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: self.generationDelayNanoseconds)
                    }
                    guard !Task.isCancelled else { return nil }
                    return self.nextGeneratedSuggestion
                },
                cancelGenerationHandler: { [weak self] in
                    self?.cancelGenerationCount += 1
                },
                overlayShow: { [weak self] suggestion, caret in
                    self?.visible = true
                    self?.overlayText = suggestion
                    self?.overlayCaret = caret
                },
                overlayUpdate: { [weak self] suggestion, caret in
                    self?.overlayText = suggestion
                    if let caret {
                        self?.overlayCaret = caret
                    }
                },
                overlayHide: { [weak self] in
                    self?.visible = false
                    self?.overlayText = nil
                    self?.hideCount += 1
                },
                isOverlayVisible: { [weak self] in
                    self?.visible ?? false
                },
                currentOverlaySuggestion: { [weak self] in
                    self?.overlayText
                }
            )
        }

        func setSnapshot(
            pid: pid_t = 1001,
            appName: String = "Notes",
            bundleID: String = "com.apple.Notes",
            beforeCaret: String,
            afterCaret: String = "",
            caretRect: CGRect? = CGRect(x: 200, y: 400, width: 2, height: 18)
        ) {
            let el = AXUIElementCreateApplication(pid)
            snapshot = TextSnapshot(
                element: el,
                appName: appName,
                bundleID: bundleID,
                beforeCaret: beforeCaret,
                afterCaret: afterCaret,
                selectedRange: CFRange(location: (beforeCaret as NSString).length, length: 0),
                caretRectAX: caretRect,
                caretRectCocoa: caretRect
            )
        }
    }

    func testMultiTabWordByWordMidWordAndSubsequentSpace() async {
        let h = Harness()
        // Mid-word completion: user typed "Hel", model suggests suffix "lo world today"
        h.setSnapshot(beforeCaret: "Hel")
        h.nextGeneratedSuggestion = "lo world today"

        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.visible)
        XCTAssertEqual(h.overlayText, "lo world today")

        // 1st Tab: completes current word "Hel" -> "Hello" (no leading space)
        XCTAssertTrue(h.coordinator.acceptNextWord())
        XCTAssertEqual(h.insertedTexts, ["lo"])
        XCTAssertEqual(h.snapshot?.beforeCaret, "Hello")
        XCTAssertTrue(h.visible)
        XCTAssertEqual(h.overlayText, " world today")

        // 2nd Tab: inserts next word with a leading space -> "Hello world"
        XCTAssertTrue(h.coordinator.acceptNextWord())
        XCTAssertEqual(h.insertedTexts, ["lo", " world"])
        XCTAssertEqual(h.snapshot?.beforeCaret, "Hello world")
        XCTAssertTrue(h.visible)
        XCTAssertEqual(h.overlayText, " today")

        // 3rd Tab: inserts final word -> "Hello world today" and hides overlay
        XCTAssertTrue(h.coordinator.acceptNextWord())
        XCTAssertEqual(h.insertedTexts, ["lo", " world", " today"])
        XCTAssertEqual(h.snapshot?.beforeCaret, "Hello world today")
        XCTAssertFalse(h.visible)
        XCTAssertNil(h.overlayText)

        // 4th Tab: no active suggestion -> passes through (returns false)
        XCTAssertFalse(h.coordinator.acceptNextWord())
    }

    func testShiftTabAcceptsEntireSuggestionWithProperSpacing() async {
        let h = Harness()
        // Case 1: After a finished word without trailing space ("Hello" + " world today")
        h.setSnapshot(beforeCaret: "Hello ")
        h.nextGeneratedSuggestion = "world today"

        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.visible)

        XCTAssertTrue(h.coordinator.acceptFullSuggestion())
        XCTAssertEqual(h.insertedTexts, ["world today"])
        XCTAssertEqual(h.snapshot?.beforeCaret, "Hello world today")
        XCTAssertFalse(h.visible)

        // Case 2: Mid-word ("Прив" + "ет как дела")
        h.insertedTexts.removeAll()
        h.setSnapshot(beforeCaret: "Прив")
        h.nextGeneratedSuggestion = "ет как дела"

        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.coordinator.acceptFullSuggestion())
        XCTAssertEqual(h.insertedTexts, ["ет как дела"])
        XCTAssertEqual(h.snapshot?.beforeCaret, "Привет как дела")
        XCTAssertFalse(h.visible)
    }

    func testStaleContextBeforeTabPassesThroughAndHidesOverlay() async {
        let h = Harness()
        h.setSnapshot(beforeCaret: "Привет как ")
        h.nextGeneratedSuggestion = "дела сегодня"

        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.visible)

        // Simulate user clicking elsewhere or editing text before pressing Tab
        h.setSnapshot(beforeCaret: "Привет как твои ")

        XCTAssertFalse(h.coordinator.acceptNextWord())
        XCTAssertTrue(h.insertedTexts.isEmpty)
        XCTAssertFalse(h.visible)

        // Also verify element change invalidates context
        h.setSnapshot(pid: 1001, beforeCaret: "Привет как ")
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.visible)

        h.setSnapshot(pid: 2002, beforeCaret: "Привет как ")
        XCTAssertFalse(h.coordinator.acceptFullSuggestion())
        XCTAssertTrue(h.insertedTexts.isEmpty)
        XCTAssertFalse(h.visible)
    }

    func testStaleContextDuringInferenceDiscardsResult() async {
        let h = Harness()
        h.setSnapshot(beforeCaret: "Напиши мне")
        h.nextGeneratedSuggestion = " письмо"
        h.generationDelayNanoseconds = 60_000_000 // 60ms

        let task = Task {
            await h.coordinator.triggerSuggestion()
        }

        // Mutate text while inference is in flight
        try? await Task.sleep(nanoseconds: 15_000_000)
        h.setSnapshot(beforeCaret: "Напиши мне пожалуйста")

        await task.value
        XCTAssertFalse(h.visible, "Stale suggestion must not be shown if text changed during inference")
        XCTAssertNil(h.coordinator.active)
    }

    func testExcludedAppsAndShortInputsAreIgnored() async {
        let h = Harness()

        // 1. Excluded bundle ID (Orion)
        h.setSnapshot(appName: "Browser", bundleID: "com.kagi.kagimacOS", beforeCaret: "Hello world")
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.generatedPrompts.isEmpty)
        XCTAssertFalse(h.visible)

        // 2. Excluded app name fragment ("Orion Preview")
        h.setSnapshot(appName: "Orion Preview", bundleID: "com.example.browser", beforeCaret: "Hello world")
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.generatedPrompts.isEmpty)

        // 3. Too short (< 3 non-whitespace chars)
        h.setSnapshot(appName: "Notes", bundleID: "com.apple.Notes", beforeCaret: "  Hi ")
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.generatedPrompts.isEmpty)

        // 4. Missing caretRectCocoa
        h.setSnapshot(appName: "Notes", bundleID: "com.apple.Notes", beforeCaret: "Hello world", caretRect: nil)
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.generatedPrompts.isEmpty)
    }

    func testRapidTypingDebouncesAndArrowKeysCancelWithoutTriggering() async {
        let h = Harness()
        h.setSnapshot(beforeCaret: "Hel")
        h.nextGeneratedSuggestion = "lo world"

        // Simulate rapid keystrokes within the 40ms debounce window
        h.coordinator.handleUserTyping(keyCode: 4)  // 'h'
        h.setSnapshot(beforeCaret: "Hell")
        h.coordinator.handleUserTyping(keyCode: 37) // 'l'
        h.setSnapshot(beforeCaret: "Hello")
        h.coordinator.handleUserTyping(keyCode: 31) // 'o'

        // Wait for debounce (40ms) + buffer
        try? await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(h.generatedPrompts, ["Hello"], "Only the final debounced state should trigger inference")
        XCTAssertTrue(h.visible)

        // Pressing Left Arrow (123) must hide overlay and not schedule new generation
        h.generatedPrompts.removeAll()
        h.coordinator.handleUserTyping(keyCode: 123)
        XCTAssertFalse(h.visible)

        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(h.generatedPrompts.isEmpty)
    }

    func testEscapeAndDisableLifecycle() async {
        let h = Harness()
        h.setSnapshot(beforeCaret: "Hello ")
        h.nextGeneratedSuggestion = "there"

        // Esc when hidden returns false
        XCTAssertFalse(h.coordinator.dismissSuggestion())

        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.visible)

        // Esc when visible returns true and hides
        XCTAssertTrue(h.coordinator.dismissSuggestion())
        XCTAssertFalse(h.visible)

        // Re-trigger and disable coordinator
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.visible)
        h.coordinator.isEnabled = false
        XCTAssertFalse(h.visible)
        XCTAssertNil(h.coordinator.active)
    }

    func testPersonalMemoryStoreFastPathAndLearningFromTabAndCompletedSentences() async {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coord_memory_\(UUID().uuidString).sqlite3")
        let store = PersonalMemoryStore(databaseURL: tempURL)
        defer {
            store.close()
            try? FileManager.default.removeItem(at: tempURL)
        }

        let h = Harness(memoryStore: store)

        // 1. Confirming a suggestion via Shift+Tab saves the completed phrase to SQLite
        h.setSnapshot(bundleID: "ru.keepcoder.Telegram", beforeCaret: "Давай созвонимся ")
        h.nextGeneratedSuggestion = "через пятнадцать минут"
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.coordinator.acceptFullSuggestion())
        XCTAssertEqual(store.phraseCount(), 1)

        // 2. Typing the beginning of that saved phrase serves instant completion from SQLite without calling LLM
        h.generatedPrompts.removeAll()
        h.setSnapshot(bundleID: "ru.keepcoder.Telegram", beforeCaret: "Давай созвон")
        await h.coordinator.triggerSuggestion()
        XCTAssertTrue(h.generatedPrompts.isEmpty, "Fast-path SQLite prefix match should skip LLM inference")
        XCTAssertTrue(h.visible)
        XCTAssertEqual(h.overlayText, "имся через пятнадцать минут")

        // 3. Passive screen learning: finishing a sentence with '.' records it in SQLite
        h.setSnapshot(bundleID: "com.apple.mail", beforeCaret: "Please find the attached report.")
        await h.coordinator.triggerSuggestion()
        XCTAssertEqual(store.phraseCount(), 2)
    }
}
