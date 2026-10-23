import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class AssistantCoordinator {
    public static let shared = AssistantCoordinator()

    internal let snapshotProvider: @MainActor (_ fast: Bool) -> TextSnapshot?
    internal let inserter: @MainActor (_ text: String, _ element: AXUIElement) -> Bool
    internal let generateHandler: @MainActor (_ prompt: String, _ maxTokens: Int) async -> String?
    internal let cancelGenerationHandler: @MainActor () -> Void
    internal let overlayShow: @MainActor (_ suggestion: String, _ caret: CGRect) -> Void
    internal let overlayUpdate: @MainActor (_ suggestion: String, _ caret: CGRect?) -> Void
    internal let overlayHide: @MainActor () -> Void
    internal let isOverlayVisible: @MainActor () -> Bool
    internal let currentOverlaySuggestion: @MainActor () -> String?
    internal let memoryStore: PersonalMemoryStore?

    private let ownedInferenceService: InferenceService?
    private var debounceTimer: Timer?
    internal let debounceInterval: TimeInterval
    private var lastRecordedSentence: String?
    private var requestID = UUID()

    /// Контекст, для которого была показана текущая подсказка.
    /// Без этой привязки Tab/Shift+Tab могли вставлять устаревший текст после клика мышью,
    /// смены окна или ввода в браузере (Orion).
    internal struct ActiveSuggestion {
        let element: AXUIElement
        let id = UUID()
        var expectedBefore: String
        var isCompletingWord: Bool
    }
    internal var active: ActiveSuggestion?

    /// Приложения, где работа через общую AX-вставку пока отключена (SPEC §13: веб-редакторы Orion требуют отдельной матрицы).
    private let excludedBundleIDs: Set<String> = [
        "com.kagi.kagimacOS"
    ]
    private let excludedNameFragments: [String] = [
        "orion"
    ]

    public var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                cancelAll()
            }
        }
    }

    public var onStatusChange: ((String) -> Void)?

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        onStatusChange?(enabled ? "Активна" : "На паузе")
    }

    private convenience init() {
        let inference = InferenceService()
        let memory = PersonalMemoryStore.shared
        self.init(
            ownedInferenceService: inference,
            memoryStore: memory,
            debounceInterval: 0.18,
            snapshotProvider: { fast in AXAdapter.shared.currentSnapshot(fast: fast) },
            inserter: { text, el in AXAdapter.shared.insert(text: text, into: el) },
            generateHandler: { prompt, maxTokens in
                let bundleID = AXAdapter.shared.currentSnapshot(fast: true)?.bundleID ?? "global"
                let examples = memory.relevantStyleExamples(for: prompt, bundleID: bundleID, limit: 4)
                return await inference.generateSuggestion(for: prompt, styleExamples: examples, maxTokens: maxTokens)
            },
            cancelGenerationHandler: { inference.cancelCurrentGeneration() },
            overlayShow: { suggestion, caret in OverlayController.shared.show(suggestion: suggestion, at: caret) },
            overlayUpdate: { suggestion, caret in OverlayController.shared.updateSuggestionText(suggestion, at: caret) },
            overlayHide: { OverlayController.shared.hide() },
            isOverlayVisible: { OverlayController.shared.isVisible },
            currentOverlaySuggestion: { OverlayController.shared.currentSuggestion }
        )
    }

    internal init(
        ownedInferenceService: InferenceService?,
        memoryStore: PersonalMemoryStore? = nil,
        debounceInterval: TimeInterval,
        snapshotProvider: @escaping @MainActor (_ fast: Bool) -> TextSnapshot?,
        inserter: @escaping @MainActor (_ text: String, _ element: AXUIElement) -> Bool,
        generateHandler: @escaping @MainActor (_ prompt: String, _ maxTokens: Int) async -> String?,
        cancelGenerationHandler: @escaping @MainActor () -> Void,
        overlayShow: @escaping @MainActor (_ suggestion: String, _ caret: CGRect) -> Void,
        overlayUpdate: @escaping @MainActor (_ suggestion: String, _ caret: CGRect?) -> Void,
        overlayHide: @escaping @MainActor () -> Void,
        isOverlayVisible: @escaping @MainActor () -> Bool,
        currentOverlaySuggestion: @escaping @MainActor () -> String?
    ) {
        self.ownedInferenceService = ownedInferenceService
        self.memoryStore = memoryStore
        self.debounceInterval = debounceInterval
        self.snapshotProvider = snapshotProvider
        self.inserter = inserter
        self.generateHandler = generateHandler
        self.cancelGenerationHandler = cancelGenerationHandler
        self.overlayShow = overlayShow
        self.overlayUpdate = overlayUpdate
        self.overlayHide = overlayHide
        self.isOverlayVisible = isOverlayVisible
        self.currentOverlaySuggestion = currentOverlaySuggestion
    }

    public func start() async {
        // 1. Запрашиваем права Accessibility (с системным диалогом, если еще не выданы)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("[Coordinator] AXIsProcessTrusted = \(trusted)")

        // 2. Загружаем модель Qwen3-1.7B Instruct в память GPU (Metal)
        onStatusChange?("Загрузка модели...")
        do {
            try await ownedInferenceService?.loadModel()
            onStatusChange?("Готова (Metal)")
        } catch {
            NSLog("[Coordinator] Model load error: \(error)")
            onStatusChange?("Ошибка модели")
        }

        // 3. Запускаем перехват клавиш (Tab / Shift+Tab / Esc / Ввод текста)
        setupEventTap()
        if !EventTapManager.shared.start() {
            onStatusChange?("Нужен доступ Accessibility")
        }

        // 4. При смене активного приложения скрываем подсказку
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelAll()
            }
        }
    }

    public func cancelAll() {
        requestID = UUID()
        debounceTimer?.invalidate()
        debounceTimer = nil
        active = nil
        cancelGenerationHandler()
        overlayHide()
    }

    internal func isExcluded(bundleID: String, appName: String) -> Bool {
        if excludedBundleIDs.contains(bundleID) { return true }
        let lower = appName.lowercased()
        return excludedNameFragments.contains(where: { lower.contains($0) })
    }

    /// Проверяет, что фокус и текст до каретки всё ещё совпадают с моментом показа подсказки.
    private func validatedContext() -> (ActiveSuggestion, TextSnapshot)? {
        guard isOverlayVisible(),
              let ctx = active,
              let snap = snapshotProvider(true),
              !isExcluded(bundleID: snap.bundleID, appName: snap.appName),
              snap.selectedRange.length == 0,
              CFEqual(snap.element, ctx.element),
              snap.beforeCaret == ctx.expectedBefore else {
            active = nil
            overlayHide()
            return nil
        }
        return (ctx, snap)
    }

    /// Принимает следующее слово по `Tab` (возвращает `true`, если клавиша перехвачена).
    internal func acceptNextWord() -> Bool {
        guard let currentSuggestion = currentOverlaySuggestion(),
              let (ctx, snap) = validatedContext() else {
            return false
        }

        guard let (firstWord, remainder) = SuggestionText.extractNextWord(from: currentSuggestion),
              !firstWord.isEmpty else {
            active = nil
            overlayHide()
            return false
        }

        let needsSpace = SuggestionText.needsLeadingSpace(
            beforeCaret: snap.beforeCaret,
            isCompletingWord: ctx.isCompletingWord
        )
        let textToInsert = needsSpace ? " " + firstWord : firstWord

        guard inserter(textToInsert, ctx.element) else {
            active = nil
            overlayHide()
            return false
        }

        let newBeforeCaret = snap.beforeCaret + textToInsert

        if remainder.isEmpty {
            let completedPhrase = PersonalMemoryStore.extractCurrentSentencePrefix(from: newBeforeCaret)
            memoryStore?.recordPhrase(completedPhrase, bundleID: snap.bundleID, weight: 2)
            active = nil
            overlayHide()
        } else {
            var updated = ctx
            updated.expectedBefore = newBeforeCaret
            updated.isCompletingWord = false // следующие слова уже отдельные
            active = updated

            let displayRemainder = remainder.hasPrefix(" ") ? remainder : " " + remainder
            overlayUpdate(displayRemainder, nil)
            // Обновляем позицию плашки чуть позже (без блокировки EventTap)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard let self, self.isOverlayVisible(),
                      self.active?.id == ctx.id,
                      self.currentOverlaySuggestion() == displayRemainder,
                      let newSnap = self.snapshotProvider(false),
                      newSnap.selectedRange.length == 0,
                      CFEqual(newSnap.element, ctx.element),
                      newSnap.beforeCaret == newBeforeCaret,
                      let caret = newSnap.caretRectCocoa else { return }
                self.overlayUpdate(displayRemainder, caret)
            }
        }
        return true
    }

    /// Принимает всю подсказку по `Shift+Tab` (возвращает `true`, если клавиша перехвачена).
    internal func acceptFullSuggestion() -> Bool {
        guard let currentSuggestion = currentOverlaySuggestion(),
              let (ctx, snap) = validatedContext() else {
            return false
        }

        let trimmed = currentSuggestion.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            active = nil
            overlayHide()
            return false
        }

        let needsSpace = SuggestionText.needsLeadingSpace(
            beforeCaret: snap.beforeCaret,
            isCompletingWord: ctx.isCompletingWord
        )
        let textToInsert = needsSpace ? " " + trimmed : trimmed

        active = nil
        overlayHide()
        guard inserter(textToInsert, ctx.element) else { return false }
        let newBeforeCaret = snap.beforeCaret + textToInsert
        let completedPhrase = PersonalMemoryStore.extractCurrentSentencePrefix(from: newBeforeCaret)
        memoryStore?.recordPhrase(completedPhrase, bundleID: snap.bundleID, weight: 2)
        return true
    }

    /// Скрывает подсказку по `Esc` (возвращает `true`, если подсказка была видима).
    internal func dismissSuggestion() -> Bool {
        let wasVisible = isOverlayVisible()
        cancelAll()
        return wasVisible
    }

    private func setupEventTap() {
        let tap = EventTapManager.shared

        tap.onTab = { [weak self] in
            self?.acceptNextWord() ?? false
        }

        tap.onShiftTab = { [weak self] in
            self?.acceptFullSuggestion() ?? false
        }

        tap.onEscape = { [weak self] in
            self?.dismissSuggestion() ?? false
        }

        tap.onTyping = { [weak self] keyCode in
            guard let self, self.isEnabled else { return }
            self.handleUserTyping(keyCode: keyCode)
        }
    }

    internal func handleUserTyping(keyCode: Int64) {
        requestID = UUID()
        // При любом нажатии клавиши сразу прячем старую подсказку и отменяем прошлую генерацию
        active = nil
        overlayHide()
        cancelGenerationHandler()
        debounceTimer?.invalidate()

        // Стрелки (123..126) или функциональные клавиши — просто сбрасываем подсказку без запуска генерации
        if (123...126).contains(keyCode) {
            return
        }

        // Пауза после последнего нажатия клавиши перед запросом к модели (SPEC §6)
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.triggerSuggestion()
            }
        }
    }

    internal func triggerSuggestion() async {
        guard isEnabled else { return }
        guard let snapshot = snapshotProvider(false), snapshot.selectedRange.length == 0 else { return }
        let generationID = UUID()
        requestID = generationID
        guard !isExcluded(bundleID: snapshot.bundleID, appName: snapshot.appName) else { return }

        let before = snapshot.beforeCaret

        // Пассивное обучение с экрана: если пользователь только что завершил предложение (. ! ? или перевод строки),
        // сохраняем его в локальную SQLite-память.
        if let completedSentence = PersonalMemoryStore.extractCompletedSentence(from: before),
           completedSentence != lastRecordedSentence {
            lastRecordedSentence = completedSentence
            memoryStore?.recordPhrase(completedSentence, bundleID: snapshot.bundleID, weight: 1)
        }

        // Не предлагаем ничего, если поле пустое или слишком короткое
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }

        // Проверяем, что мы смогли вычислить экранные координаты каретки
        guard let initialCaret = snapshot.caretRectCocoa else { return }

        // 1. Быстрый путь (SQLite PersonalMemoryStore < 1 мс): проверяем точное совпадение частой фразы пользователя
        if let memoryMatch = memoryStore?.matchPrefixContinuation(for: before, bundleID: snapshot.bundleID) {
            let completingWord = before.last?.isWhitespace == false && memoryMatch.first?.isWhitespace != true
            active = ActiveSuggestion(
                element: snapshot.element,
                expectedBefore: before,
                isCompletingWord: completingWord
            )
            overlayShow(memoryMatch, initialCaret)
            return
        }

        // 2. Генерация через Qwen3-1.7B-Instruct (с подстановкой релевантных фраз пользователя из SQLite)
        guard let suggestion = await generateHandler(before, 20),
              !Task.isCancelled, isEnabled, requestID == generationID else {
            return
        }

        // Проверяем, что пользователь не изменил текст и не сменил фокус, пока модель думала
        guard let latest = snapshotProvider(false),
              latest.selectedRange.length == 0,
              !isExcluded(bundleID: latest.bundleID, appName: latest.appName),
              CFEqual(latest.element, snapshot.element),
              latest.beforeCaret == before,
              let latestCaret = latest.caretRectCocoa else {
            return
        }

        let completingWord = before.last?.isWhitespace == false && suggestion.first?.isWhitespace != true
        active = ActiveSuggestion(
            element: latest.element,
            expectedBefore: before,
            isCompletingWord: completingWord
        )
        overlayShow(suggestion, latestCaret)
    }
}
