import Foundation

/// Чистая (без UI/MLX/AX) логика обработки текста подсказок — вынесена для юнит-тестов.
enum SuggestionText {
    /// Возвращает подсказку. Если пользователь в середине слова, а модель начала НОВОЕ слово
    /// (вывод начинается с пробела), ведущий пробел сохраняется — по нему координатор
    /// отличает «допечатать слово» от «начать новое» (иначе была склейка Hello+world).
    static func format(_ text: String, prompt: String, maxWords: Int) -> String? {
        // Очищаем возможные служебные теги Qwen3 (<think>...</think>, <|im_end|>, <|endoftext|>)
        var sanitized = text
        if let thinkEndRange = sanitized.range(of: "</think>") {
            sanitized = String(sanitized[thinkEndRange.upperBound...])
        }
        sanitized = sanitized
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")

        // Только первая строка (но ведущие переводы строк отбрасываем)
        let body = sanitized.drop(while: { $0.isNewline })
        let cleaned = body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let promptEndsWithSpace = prompt.last?.isWhitespace ?? true
        let startsWithSpace = cleaned.first.map { $0 == " " || $0 == "\t" } ?? false

        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard let firstWord = words.first else { return nil }
        let joined = words.prefix(maxWords).joined(separator: " ")

        // Фильтр числовых артефактов — только если контекст не числовой
        // (код, даты, суммы: последний токен промпта содержит цифру — не фильтруем).
        let lastPromptWord = prompt.split(whereSeparator: { $0.isWhitespace }).last ?? ""
        let promptHasNumber = lastPromptWord.contains(where: { $0.isNumber })
        // Время/числа вида "10:25", "3.5", "1,000" тоже считаем числовыми артефактами
        let isNumeric = !firstWord.isEmpty
            && firstWord.contains(where: { $0.isNumber })
            && firstWord.allSatisfy({ $0.isNumber || $0.isPunctuation })
        if !promptHasNumber, isNumeric {
            return nil
        }

        if !promptEndsWithSpace && startsWithSpace {
            return " " + joined
        }
        return joined
    }

    /// Собирает входную строку для Qwen3-1.7B-Instruct с отключенным режимом `<think>`
    /// и подстановкой релевантных примеров стиля пользователя (RU / EN).
    static func buildInstructInput(prompt: String, styleExamples: [String] = []) -> String {
        let lang = PersonalMemoryStore.detectLanguage(prompt)
        let systemInstruction: String
        if lang == "ru" {
            systemInstruction = "Ты — локальный ассистент автодополнения текста (русский и английский). Продолжи текст пользователя естественно и по смыслу, без пояснений."
        } else {
            systemInstruction = "You are a local text autocompletion assistant (English and Russian). Continue the user's text naturally and concisely without explanations."
        }

        var examplesBlock = ""
        let filteredExamples = styleExamples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !filteredExamples.isEmpty {
            let header = lang == "ru" ? "Примеры частых фраз и стиля пользователя:" : "Examples of the user's frequent phrases and style:"
            let lines = filteredExamples.prefix(4).map { "- \($0)" }.joined(separator: "\n")
            examplesBlock = "\n\(header)\n\(lines)"
        }

        let userPrompt = lang == "ru"
            ? "Продолжи этот текст с того места, где он обрывается"
            : "Continue this text seamlessly from where it stops"

        return "<|im_start|>system\n\(systemInstruction)\(examplesBlock)<|im_end|>\n<|im_start|>user\n\(userPrompt)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n\(prompt)"
    }

    /// Отделяет первое слово подсказки; remainder начинается с одного пробела либо пуст.
    static func extractNextWord(from text: String) -> (word: String, remainder: String)? {
        guard !text.isEmpty else { return nil }

        let trimmedLeading = text.drop(while: { $0.isWhitespace })
        guard !trimmedLeading.isEmpty else { return nil }

        var wordEnd = trimmedLeading.startIndex
        while wordEnd < trimmedLeading.endIndex && !trimmedLeading[wordEnd].isWhitespace {
            wordEnd = trimmedLeading.index(after: wordEnd)
        }

        let word = String(trimmedLeading[..<wordEnd])
        let trimmedRemainder = String(trimmedLeading[wordEnd...]).trimmingCharacters(in: .whitespaces)
        return (word, trimmedRemainder.isEmpty ? "" : " " + trimmedRemainder)
    }

    /// Решает, нужен ли пробел перед вставляемым текстом.
    static func needsLeadingSpace(beforeCaret: String, isCompletingWord: Bool) -> Bool {
        let endsWithSpace = beforeCaret.last?.isWhitespace ?? true
        return !isCompletingWord && !endsWithSpace
    }

    /// Обрезка промпта до `limit` символов по границе слова.
    static func trimPrompt(_ prompt: String, limit: Int) -> String {
        guard prompt.count > limit else { return prompt }
        var trimmed = String(prompt.suffix(limit))
        if let firstBreak = trimmed.firstIndex(where: { $0.isWhitespace }) {
            trimmed = String(trimmed[trimmed.index(after: firstBreak)...])
        }
        return trimmed
    }
}
