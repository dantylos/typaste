import Foundation

/// Чистая (без UI/MLX/AX) логика обработки текста подсказок — вынесена для юнит-тестов.
enum SuggestionText {
    /// Возвращает подсказку. Если пользователь в середине слова, а модель начала НОВОЕ слово
    /// (вывод начинается с пробела), ведущий пробел сохраняется — по нему координатор
    /// отличает «допечатать слово» от «начать новое» (иначе была склейка Hello+world).
    static func format(_ text: String, prompt: String, maxWords: Int) -> String? {
        // Только первая строка (но ведущие переводы строк отбрасываем)
        let body = text.drop(while: { $0.isNewline })
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
