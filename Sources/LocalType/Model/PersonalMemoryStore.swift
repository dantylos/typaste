import Foundation
import SQLite3

/// Личное локальное хранилище (SQLite3) для запоминания частых фраз и стиля пользователя
/// с поддержкой русского и английского языков (RU / EN).
@MainActor
public final class PersonalMemoryStore {
    public static let shared = PersonalMemoryStore()

    private var db: OpaquePointer?
    public let databaseURL: URL

    /// Минимальная длина сохраняемой фразы.
    nonisolated public static let minPhraseLength = 6
    /// Максимальная длина сохраняемой фразы.
    nonisolated public static let maxPhraseLength = 240

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = appSupport.appendingPathComponent("LocalType", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.init(databaseURL: folder.appendingPathComponent("personal_memory.sqlite3"))
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        openAndMigrate()
    }

    /// Закрывает соединение с SQLite (вызывается при необходимости в тестах).
    public func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    private func openAndMigrate() {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            NSLog("[PersonalMemoryStore] Failed to open SQLite database at %@", databaseURL.path)
            return
        }
        self.db = handle

        let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS user_phrases (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL UNIQUE,
            normalized TEXT NOT NULL,
            bundle_id TEXT NOT NULL,
            language TEXT NOT NULL,
            use_count INTEGER NOT NULL DEFAULT 1,
            last_used_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_user_phrases_norm ON user_phrases(normalized);
        CREATE INDEX IF NOT EXISTS idx_user_phrases_bundle_lang ON user_phrases(bundle_id, language, use_count DESC, last_used_at DESC);
        """
        sqlite3_exec(handle, schema, nil, nil, nil)
    }

    // MARK: - Language & Text Normalization

    /// Определяет язык текста ("ru" или "en") по преобладанию кириллических / латинских букв.
    nonisolated public static func detectLanguage(_ text: String) -> String {
        var cyrillicCount = 0
        var latinCount = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillicCount += 1
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                latinCount += 1
            }
        }
        return cyrillicCount >= latinCount && cyrillicCount > 0 ? "ru" : "en"
    }

    /// Нормализует строку для регистронезависимого префиксного поиска (схлопывает пробелы и приводит к нижнему регистру).
    nonisolated public static func normalize(_ text: String) -> String {
        let components = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ").lowercased()
    }

    /// Извлекает последнее незаконченное предложение / реплику перед курсором.
    nonisolated public static func extractCurrentSentencePrefix(from beforeCaret: String) -> String {
        let lastLine = beforeCaret.components(separatedBy: .newlines).last ?? beforeCaret
        var startIdx = lastLine.startIndex
        var idx = lastLine.startIndex
        while idx < lastLine.endIndex {
            let ch = lastLine[idx]
            let nextIdx = lastLine.index(after: idx)
            if (ch == "." || ch == "!" || ch == "?"),
               nextIdx < lastLine.endIndex,
               lastLine[nextIdx].isWhitespace {
                var afterSpaces = nextIdx
                while afterSpaces < lastLine.endIndex && lastLine[afterSpaces].isWhitespace {
                    afterSpaces = lastLine.index(after: afterSpaces)
                }
                if afterSpaces < lastLine.endIndex {
                    startIdx = afterSpaces
                }
            }
            idx = nextIdx
        }
        return String(lastLine[startIdx...])
    }

    /// Извлекает последнее полностью завершенное предложение, если пользователь только что поставил знак завершения или перевод строки.
    nonisolated public static func extractCompletedSentence(from beforeCaret: String) -> String? {
        let trimmedRight = beforeCaret.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard let lastChar = trimmedRight.last,
              lastChar == "." || lastChar == "!" || lastChar == "?" || beforeCaret.hasSuffix("\n") else {
            return nil
        }

        let lines = trimmedRight.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let lastLine = lines.last else { return nil }

        var sentences: [String] = []
        var current = ""
        for ch in lastLine {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let leftover = current.trimmingCharacters(in: .whitespaces)
        if !leftover.isEmpty {
            sentences.append(leftover)
        }
        return sentences.last
    }

    // MARK: - Recording Phrases

    /// Сохраняет или увеличивает счетчик использования фразы пользователя.
    public func recordPhrase(_ rawPhrase: String, bundleID: String = "global", weight: Int = 1) {
        guard let db else { return }

        let cleaned = rawPhrase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard cleaned.count >= Self.minPhraseLength,
              cleaned.count <= Self.maxPhraseLength else {
            return
        }

        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { return }
        guard !words.contains(where: { $0.count > 32 }) else { return }

        let norm = Self.normalize(cleaned)
        let lang = Self.detectLanguage(cleaned)
        let now = Date().timeIntervalSince1970
        let increment = max(1, weight)

        let sql = """
        INSERT INTO user_phrases (text, normalized, bundle_id, language, use_count, last_used_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(text) DO UPDATE SET
            use_count = user_phrases.use_count + excluded.use_count,
            last_used_at = excluded.last_used_at,
            bundle_id = excluded.bundle_id;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, cleaned, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, norm, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, bundleID, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 4, lang, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 5, Int32(increment))
        sqlite3_bind_double(stmt, 6, now)

        _ = sqlite3_step(stmt)
    }

    // MARK: - Retrieving Completions & Style Examples

    /// Мгновенно ищет продолжение частой фразы по префиксу текущего предложения (< 1 мс).
    public func matchPrefixContinuation(
        for beforeCaret: String,
        bundleID: String = "global",
        maxWords: Int = 4
    ) -> String? {
        guard let db else { return nil }

        let sentencePrefix = Self.extractCurrentSentencePrefix(from: beforeCaret)
        let normPrefix = Self.normalize(sentencePrefix)
        guard normPrefix.count >= 3 else { return nil }

        let sql = """
        SELECT text FROM user_phrases
        WHERE normalized LIKE (?1 || '%')
          AND length(normalized) > length(?1)
        ORDER BY (CASE WHEN bundle_id = ?2 THEN 1 ELSE 0 END) DESC,
                 use_count DESC,
                 last_used_at DESC
        LIMIT 5;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, normPrefix, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, bundleID, -1, Self.sqliteTransient)

        let trimmedSentencePrefix = sentencePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentencePrefix.isEmpty else { return nil }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let candidate = String(cString: cStr)

            if let range = candidate.range(
                of: trimmedSentencePrefix,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored]
            ) {
                var suffix = String(candidate[range.upperBound...])
                if beforeCaret.last?.isWhitespace == true {
                    suffix = String(suffix.drop(while: { $0.isWhitespace }))
                }
                if let formatted = SuggestionText.format(suffix, prompt: beforeCaret, maxWords: maxWords) {
                    return formatted
                }
            }
        }

        return nil
    }

    /// Возвращает до `limit` релевантных фраз пользователя (на том же языке и с приоритетом текущего приложения)
    /// для подстановки в контекст модели `Qwen3-1.7B-Instruct`.
    public func relevantStyleExamples(
        for beforeCaret: String,
        bundleID: String = "global",
        limit: Int = 4
    ) -> [String] {
        guard let db, limit > 0 else { return [] }

        let lang = Self.detectLanguage(beforeCaret)
        let sql = """
        SELECT text FROM user_phrases
        WHERE language = ?1
        ORDER BY (CASE WHEN bundle_id = ?2 THEN 1 ELSE 0 END) DESC,
                 use_count DESC,
                 last_used_at DESC
        LIMIT ?3;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, lang, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, bundleID, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cStr))
            }
        }
        return results
    }

    /// Возвращает общее количество сохраненных уникальных фраз в БД.
    public func phraseCount() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM user_phrases;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Очищает все сохраненные фразы.
    public func clearAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM user_phrases;", nil, nil, nil)
    }
}
