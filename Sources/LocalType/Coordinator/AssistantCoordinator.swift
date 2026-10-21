import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class AssistantCoordinator {
    public static let shared = AssistantCoordinator()

    private let inferenceService = InferenceService()
    private var debounceTimer: Timer?
    private var currentElement: AXUIElement?
    private var lastPrompt: String = ""
    public private(set) var isEnabled: Bool = true

    private init() {
        setupEventTap()
    }

    public func start() async {
        NSLog("[AssistantCoordinator] Starting assistant...")
        do {
            try await inferenceService.loadModel()
            NSLog("[AssistantCoordinator] Model ready. Starting EventTap...")
            _ = EventTapManager.shared.start()
        } catch {
            NSLog("[AssistantCoordinator] Failed to load model: %@", error.localizedDescription)
        }
    }

    private var isCompletingWord: Bool = false

    public func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        if !enabled {
            OverlayController.shared.hide()
            inferenceService.cancelCurrentGeneration()
        }
    }

    private func setupEventTap() {
        // Обработка клавиши Tab: принять по одному слову
        EventTapManager.shared.onTab = { [weak self] in
            guard let self, self.isEnabled else { return false }

            // Полностью игнорируем Orion
            if let snap = AXAdapter.shared.currentSnapshot(),
               snap.bundleID == "com.kagi.kagimacOS" || snap.appName.localizedCaseInsensitiveContains("orion") {
                return false
            }

            guard OverlayController.shared.isVisible,
                  let fullSuggestion = OverlayController.shared.currentSuggestion else {
                return false
            }

            let snap = AXAdapter.shared.currentSnapshot()
            guard let el = snap?.element ?? self.currentElement else {
                return false
            }

            let beforeCaret = snap?.beforeCaret ?? self.lastPrompt
            let endsWithSpace = beforeCaret.hasSuffix(" ") || beforeCaret.hasSuffix("\t") || beforeCaret.hasSuffix("\n")

            guard let (word, remainder) = self.extractNextWord(from: fullSuggestion) else {
                OverlayController.shared.hide()
                return false
            }

            let textToInsert: String
            if self.isCompletingWord {
                // Допечатываем половину слова: никаких пробелов ни до, ни после!
                textToInsert = word
                self.isCompletingWord = false
            } else if endsWithSpace || beforeCaret.isEmpty {
                // Пробел уже напечатан пользователем
                textToInsert = word
            } else {
                // Новое слово после символа без пробела
                textToInsert = " " + word
            }

            NSLog("[AssistantCoordinator] Tab pressed! Inserting: '%@'", textToInsert)
            let success = AXAdapter.shared.insert(text: textToInsert, into: el)

            let trimmedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if success && !trimmedRemainder.isEmpty {
                // Мгновенно обновляем текст подсказки в плашке
                OverlayController.shared.updateSuggestionText(remainder)

                // Через 60 мс мягко уточняем экранную позицию каретки
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    if let freshSnapshot = AXAdapter.shared.currentSnapshot() {
                        self.currentElement = freshSnapshot.element
                        self.lastPrompt = freshSnapshot.beforeCaret
                        if let freshCaret = freshSnapshot.caretRectCocoa {
                            OverlayController.shared.updateSuggestionText(remainder, at: freshCaret)
                        }
                    }
                }
            } else {
                OverlayController.shared.hide()
            }

            return success
        }

        // Обработка клавиши Shift+Tab: принять всю подсказку целиком
        EventTapManager.shared.onShiftTab = { [weak self] in
            guard let self, self.isEnabled else { return false }

            // Полностью игнорируем Orion
            if let snap = AXAdapter.shared.currentSnapshot(),
               snap.bundleID == "com.kagi.kagimacOS" || snap.appName.localizedCaseInsensitiveContains("orion") {
                return false
            }

            guard OverlayController.shared.isVisible,
                  let fullSuggestion = OverlayController.shared.currentSuggestion else {
                return false
            }

            let snap = AXAdapter.shared.currentSnapshot()
            guard let el = snap?.element ?? self.currentElement else {
                return false
            }

            let beforeCaret = snap?.beforeCaret ?? self.lastPrompt
            let endsWithSpace = beforeCaret.hasSuffix(" ") || beforeCaret.hasSuffix("\t") || beforeCaret.hasSuffix("\n")

            let cleanedSuggestion = fullSuggestion.trimmingCharacters(in: .whitespaces)
            let textToInsert: String
            if self.isCompletingWord {
                textToInsert = cleanedSuggestion
            } else if endsWithSpace || beforeCaret.isEmpty {
                textToInsert = cleanedSuggestion
            } else {
                textToInsert = " " + cleanedSuggestion
            }
            self.isCompletingWord = false

            NSLog("[AssistantCoordinator] Shift+Tab pressed! Inserting all: '%@'", textToInsert)
            let success = AXAdapter.shared.insert(text: textToInsert, into: el)
            OverlayController.shared.hide()
            return success
        }

        // Обработка клавиши Escape
        EventTapManager.shared.onEscape = { [weak self] in
            guard let self, self.isEnabled else { return false }
            if OverlayController.shared.isVisible {
                NSLog("[AssistantCoordinator] Escape pressed! Dismissing suggestion.")
                OverlayController.shared.hide()
                self.inferenceService.cancelCurrentGeneration()
                return true
            }
            return false
        }

        // Обработка любого другого ввода
        EventTapManager.shared.onTyping = { [weak self] keyCode in
            guard let self, self.isEnabled else { return }
            self.handleUserTyping(keyCode: keyCode)
        }
    }

    private func handleUserTyping(keyCode: CGKeyCode) {
        // Скрываем текущую плашку при продолжении набора
        if OverlayController.shared.isVisible {
            OverlayController.shared.hide()
        }

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
        guard let snapshot = AXAdapter.shared.currentSnapshot() else {
            return
        }

        // Подсказки в браузере Orion полностью отключены по требованию пользователя
        if snapshot.bundleID == "com.kagi.kagimacOS" || snapshot.appName.localizedCaseInsensitiveContains("orion") {
            return
        }

        let beforeCaret = snapshot.beforeCaret
        let trimmed = beforeCaret.trimmingCharacters(in: .whitespacesAndNewlines)

        // Не вызываем модель на пустом поле или слишком коротком вводе (< 3 символов)
        guard trimmed.count >= 3 else {
            return
        }

        // Если каретка не имеет известных экранных координат — плашку показать нельзя
        guard snapshot.caretRectCocoa != nil else {
            return
        }

        self.currentElement = snapshot.element
        self.lastPrompt = beforeCaret

        // Определяем, допечатывает ли пользователь половину слова
        let isMidWord = !beforeCaret.isEmpty
            && !beforeCaret.hasSuffix(" ")
            && !beforeCaret.hasSuffix("\t")
            && !beforeCaret.hasSuffix("\n")
        self.isCompletingWord = isMidWord

        // Запуск инференса на GPU/Metal
        guard let suggestion = await inferenceService.generateSuggestion(for: beforeCaret, maxTokens: 20) else {
            return
        }

        // Проверяем, что за время инференса фокус и текст не изменились
        guard let latest = AXAdapter.shared.currentSnapshot(),
              latest.beforeCaret == beforeCaret,
              let latestCocoaCaret = latest.caretRectCocoa else {
            return
        }

        // Показываем плашку с подсказкой рядом с курсором
        OverlayController.shared.show(suggestion: suggestion, at: latestCocoaCaret)
    }

    private func extractNextWord(from text: String) -> (word: String, remainder: String)? {
        guard !text.isEmpty else { return nil }

        // Отбрасываем любые начальные пробелы
        let trimmedLeading = text.drop(while: { $0.isWhitespace })
        guard !trimmedLeading.isEmpty else { return nil }

        var wordEnd = trimmedLeading.startIndex
        while wordEnd < trimmedLeading.endIndex && !trimmedLeading[wordEnd].isWhitespace {
            wordEnd = trimmedLeading.index(after: wordEnd)
        }

        let word = String(trimmedLeading[..<wordEnd])
        var remainder = String(trimmedLeading[wordEnd...])

        // Если в остатке есть символы, гарантируем аккуратный пробел перед следующим словом
        let trimmedRemainder = remainder.trimmingCharacters(in: .whitespaces)
        if !trimmedRemainder.isEmpty {
            remainder = " " + trimmedRemainder
        } else {
            remainder = ""
        }

        return (word, remainder)
    }
}
