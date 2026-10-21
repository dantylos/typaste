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

    public func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        if !enabled {
            OverlayController.shared.hide()
            inferenceService.cancelCurrentGeneration()
        }
    }

    private func setupEventTap() {
        // Обработка клавиши Tab
        EventTapManager.shared.onTab = { [weak self] in
            guard let self, self.isEnabled else { return false }
            if OverlayController.shared.isVisible,
               let suggestion = OverlayController.shared.currentSuggestion,
               let el = self.currentElement {
                NSLog("[AssistantCoordinator] Tab pressed! Inserting: %@", suggestion)
                let success = AXAdapter.shared.insert(text: suggestion, into: el)
                OverlayController.shared.hide()
                return success
            }
            return false
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
}
