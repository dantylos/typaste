import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class AssistantCoordinator {
    public static let shared = AssistantCoordinator()

    /// Приложения, в которых подсказки полностью отключены.
    private static let excludedBundleIDs: Set<String> = ["com.kagi.kagimacOS"]
    private static let excludedNameFragments: [String] = ["orion"]

    /// Состояние показанной подсказки. Привязано к элементу и тексту до каретки:
    /// если фокус/текст изменились (мышь, другое поле), Tab не перехватывается.
    private struct ActiveSuggestion {
        var element: AXUIElement
        var expectedBefore: String
        var isCompletingWord: Bool
    }

    private let inferenceService = InferenceService()
    private var debounceTimer: Timer?
    private var active: ActiveSuggestion?
    public private(set) var isEnabled: Bool = true

    /// Человекочитаемый статус (для меню статус-бара).
    public var onStatusChange: ((String) -> Void)?

    private init() {
        setupEventTap()
    }

    public func start() async {
        NSLog("[AssistantCoordinator] Starting assistant...")
        onStatusChange?("Загрузка модели…")
        do {
            try await inferenceService.loadModel()
        } catch {
            NSLog("[AssistantCoordinator] Failed to load model: %@", error.localizedDescription)
            onStatusChange?("Ошибка модели: \(error.localizedDescription)")
            return
        }
        NSLog("[AssistantCoordinator] Model ready. Starting EventTap...")
        await ensureEventTap()
    }

    /// Запрашивает права один раз и повторяет создание tap, пока пользователь их не выдаст.
    private func ensureEventTap() async {
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            NSLog("[AssistantCoordinator] Accessibility permission missing; prompting")
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        while !Task.isCancelled {
            if EventTapManager.shared.start() {
                onStatusChange?("Готово")
                return
            }
            onStatusChange?("Нужны права: Универсальный доступ и Мониторинг ввода")
            try? await Task.sleep(for: .seconds(2))
        }
    }

    public func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        if !enabled {
            debounceTimer?.invalidate()
            active = nil
            OverlayController.shared.hide()
            inferenceService.cancelCurrentGeneration()
        }
    }

    private static func isExcluded(bundleID: String, appName: String) -> Bool {
        if excludedBundleIDs.contains(bundleID) { return true }
        return excludedNameFragments.contains { appName.localizedCaseInsensitiveContains($0) }
    }

    /// Проверяет, что подсказка видна и всё ещё относится к тому же полю и тексту.
    /// Вызывается из колбэка event tap: используются только быстрые AX-вызовы,
    /// и только если подсказка действительно показана (иначе Tab проходит без AX-запросов).
    private func validatedContext() -> (snapshot: TextSnapshot, active: ActiveSuggestion, suggestion: String)? {
        guard isEnabled,
              OverlayController.shared.isVisible,
              let suggestion = OverlayController.shared.currentSuggestion,
              let active else { return nil }

        guard let snap = AXAdapter.shared.currentSnapshot(fast: true),
              !Self.isExcluded(bundleID: snap.bundleID, appName: snap.appName),
              CFEqual(snap.element, active.element),
              snap.beforeCaret == active.expectedBefore else {
            self.active = nil
            OverlayController.shared.hide()
            return nil
        }
        return (snap, active, suggestion)
    }

    private func setupEventTap() {
        // Tab: принять одно слово
        EventTapManager.shared.onTab = { [weak self] in
            guard let self, let ctx = self.validatedContext() else { return false }

            guard let (word, remainder) = SuggestionText.extractNextWord(from: ctx.suggestion) else {
                self.active = nil
                OverlayController.shared.hide()
                return false
            }

            let before = ctx.snapshot.beforeCaret
            // Пробел нужен только для нового слова после символа без пробела.
            let needsSpace = SuggestionText.needsLeadingSpace(
                beforeCaret: before, isCompletingWord: ctx.active.isCompletingWord)
            let textToInsert = (needsSpace ? " " : "") + word

            NSLog("[AssistantCoordinator] Tab pressed! Inserting: '%@'", textToInsert)
            let success = AXAdapter.shared.insert(text: textToInsert, into: ctx.snapshot.element)

            let trimmedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if success && !trimmedRemainder.isEmpty {
                self.active?.expectedBefore = before + textToInsert
                self.active?.isCompletingWord = false
                OverlayController.shared.updateSuggestionText(remainder)

                // Через 60 мс мягко уточняем экранную позицию каретки
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    if let fresh = AXAdapter.shared.currentSnapshot(), let caret = fresh.caretRectCocoa {
                        OverlayController.shared.updateSuggestionText(remainder, at: caret)
                    }
                }
            } else {
                self.active = nil
                OverlayController.shared.hide()
            }
            return success
        }

        // Shift+Tab: принять всю подсказку
        EventTapManager.shared.onShiftTab = { [weak self] in
            guard let self, let ctx = self.validatedContext() else { return false }

            let cleaned = ctx.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                self.active = nil
                OverlayController.shared.hide()
                return false
            }
            let needsSpace = SuggestionText.needsLeadingSpace(
                beforeCaret: ctx.snapshot.beforeCaret, isCompletingWord: ctx.active.isCompletingWord)
            let textToInsert = (needsSpace ? " " : "") + cleaned

            NSLog("[AssistantCoordinator] Shift+Tab pressed! Inserting all: '%@'", textToInsert)
            let success = AXAdapter.shared.insert(text: textToInsert, into: ctx.snapshot.element)
            self.active = nil
            OverlayController.shared.hide()
            return success
        }

        // Escape
        EventTapManager.shared.onEscape = { [weak self] in
            guard let self, self.isEnabled else { return false }
            if OverlayController.shared.isVisible {
                NSLog("[AssistantCoordinator] Escape pressed! Dismissing suggestion.")
                self.active = nil
                OverlayController.shared.hide()
                self.inferenceService.cancelCurrentGeneration()
                return true
            }
            return false
        }

        // Любой другой ввод
        EventTapManager.shared.onTyping = { [weak self] keyCode in
            guard let self, self.isEnabled else { return }
            self.handleUserTyping(keyCode: keyCode)
        }
    }

    private func handleUserTyping(keyCode: CGKeyCode) {
        active = nil
        if OverlayController.shared.isVisible {
            OverlayController.shared.hide()
        }
        // Устаревшая генерация больше не нужна
        inferenceService.cancelCurrentGeneration()

        debounceTimer?.invalidate()

        // Debounce ~180 мс после последнего нажатия клавиши
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.triggerSuggestion()
            }
        }
    }

    private func triggerSuggestion() async {
        guard isEnabled else { return }
        guard let snapshot = AXAdapter.shared.currentSnapshot() else { return }

        if Self.isExcluded(bundleID: snapshot.bundleID, appName: snapshot.appName) { return }

        let beforeCaret = snapshot.beforeCaret
        // Не вызываем модель на пустом поле или слишком коротком вводе (< 3 символов)
        guard beforeCaret.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        // Без экранных координат каретки плашку показать нельзя
        guard snapshot.caretRectCocoa != nil else { return }

        let isMidWord = !(beforeCaret.last?.isWhitespace ?? true)

        let started = Date()
        guard let suggestion = await inferenceService.generateSuggestion(for: beforeCaret, maxTokens: 20) else {
            NSLog("[AssistantCoordinator] No suggestion for tail '%@'", String(beforeCaret.suffix(30)))
            return
        }
        NSLog("[AssistantCoordinator] Suggestion '%@' (%.0f ms) for tail '%@'",
              suggestion, Date().timeIntervalSince(started) * 1000, String(beforeCaret.suffix(30)))

        // За время инференса фокус и текст не должны измениться
        guard isEnabled,
              let latest = AXAdapter.shared.currentSnapshot(),
              CFEqual(latest.element, snapshot.element),
              latest.beforeCaret == beforeCaret,
              let latestCocoaCaret = latest.caretRectCocoa else {
            return
        }

        // Допечатываем слово, только если подсказка НЕ начинается с пробела (иначе модель начала новое слово)
        let startsWithSpace = suggestion.first.map { $0 == " " || $0 == "\t" } ?? false
        active = ActiveSuggestion(
            element: latest.element,
            expectedBefore: beforeCaret,
            isCompletingWord: isMidWord && !startsWithSpace
        )

        OverlayController.shared.show(suggestion: suggestion, at: latestCocoaCaret)
    }
}
