import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public struct TextSnapshot {
    public let element: AXUIElement
    public let appName: String
    public let bundleID: String
    public let beforeCaret: String
    public let afterCaret: String
    public let selectedRange: CFRange
    public let caretRectAX: CGRect?
    public let caretRectCocoa: CGRect?

    public init(
        element: AXUIElement,
        appName: String,
        bundleID: String,
        beforeCaret: String,
        afterCaret: String,
        selectedRange: CFRange,
        caretRectAX: CGRect?,
        caretRectCocoa: CGRect?
    ) {
        self.element = element
        self.appName = appName
        self.bundleID = bundleID
        self.beforeCaret = beforeCaret
        self.afterCaret = afterCaret
        self.selectedRange = selectedRange
        self.caretRectAX = caretRectAX
        self.caretRectCocoa = caretRectCocoa
    }
}

@MainActor
public final class AXAdapter {
    public static let shared = AXAdapter()
    private let timeout: Float = 0.3
    /// Короткий таймаут для вызовов из колбэка CGEventTap (не блокируем ввод всей системы).
    private let fastTimeout: Float = 0.08

    /// Позволяет подменять отправку клавиш Cmd+V в интеграционных тестах без генерации HID-событий в активное окно.
    internal var postKeyboardPaste: @MainActor () -> Bool = { AXAdapter.defaultPostKeyboardPaste() }

    private struct ClipboardTransaction {
        let backup: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
    }
    private var clipboardTransactions: [NSPasteboard.Name: ClipboardTransaction] = [:]

    private init() {}

    private func restoreClipboard(_ pasteboard: NSPasteboard, changeCount: Int) {
        guard let transaction = clipboardTransactions[pasteboard.name],
              transaction.changeCount == changeCount else { return }
        clipboardTransactions[pasteboard.name] = nil
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let items = transaction.backup.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Разрезает строку по UTF-16 диапазону выделения (`kAXSelectedTextRangeAttribute`).
    internal static func sliceText(_ fullText: String, selectedRange: CFRange) -> (before: String, after: String)? {
        let nsString = fullText as NSString
        let loc = selectedRange.location
        let len = selectedRange.length
        guard loc >= 0, len >= 0, loc <= nsString.length, len <= nsString.length - loc else { return nil }

        let beforeCaret = nsString.substring(to: loc)
        let afterCaret = (loc + len <= nsString.length)
            ? nsString.substring(from: loc + len)
            : ""
        return (beforeCaret, afterCaret)
    }

    /// - Parameter fast: короткий AX-таймаут и без расчёта экранного прямоугольника каретки.
    public func currentSnapshot(fast: Bool = false) -> TextSnapshot? {
        guard let (el, app) = focusedElement(timeout: fast ? fastTimeout : timeout) else { return nil }

        // Проверяем, не является ли поле защищенным (пароль)
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String else {
            return nil
        }

        var selRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
              let selRangeVal = selRangeRef,
              CFGetTypeID(selRangeVal) == AXValueGetTypeID() else {
            return nil
        }

        let axVal = unsafeDowncast(selRangeVal, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }

        guard let sliced = Self.sliceText(fullText, selectedRange: range) else { return nil }

        let axCaret = fast ? nil : calculateCaretRect(el: el, location: range.location, fullText: fullText)
        let cocoaCaret = axCaret.map { convertAXToCocoa(axRect: $0) }

        return TextSnapshot(
            element: el,
            appName: app?.localizedName ?? "Unknown",
            bundleID: app?.bundleIdentifier ?? "Unknown",
            beforeCaret: sliced.before,
            afterCaret: sliced.after,
            selectedRange: range,
            caretRectAX: axCaret,
            caretRectCocoa: cocoaCaret
        )
    }

    public func insert(text: String, into element: AXUIElement) -> Bool {
        insert(
            text: text,
            into: element,
            axSetSelectedText: { el, str in
                AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, str as CFString)
            },
            axCopyValue: { el in
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success else {
                    return nil
                }
                return ref as? String
            },
            fallbackPaste: { [weak self] str in
                self?.insertViaTransientClipboard(str) ?? false
            }
        )
    }

    internal func insert(
        text: String,
        into element: AXUIElement,
        axSetSelectedText: (AXUIElement, String) -> AXError,
        axCopyValue: (AXUIElement) -> String?,
        fallbackPaste: (String) -> Bool
    ) -> Bool {
        // Запоминаем текущее значение поля перед попыткой вставки
        let beforeVal = axCopyValue(element)

        // Tier 1 (SPEC §7): Прямая вставка через kAXSelectedTextAttribute
        let error = axSetSelectedText(element, text)
        if error == .success {
            return true
        }

        // Проверяем: многие приложения (включая Telegram macOS) успешно применяют вставку
        // через kAXSelectedTextAttribute, но возвращают ошибку -25200 (kAXErrorFailure).
        // Если значение поля изменилось — вставка фактически удалась, Tier 2 вызывать НЕ нужно!
        if let before = beforeVal, let after = axCopyValue(element), after != before {
            NSLog("[AXAdapter] Tier 1 returned error %d, but AXValue changed. Insertion succeeded, skipping Tier 2 clipboard paste.", error.rawValue)
            return true
        }

        NSLog("[AXAdapter] Tier 1 insert failed with error %d, engaging Tier 2 fallback", error.rawValue)
        return fallbackPaste(text)
    }

    internal func insertViaTransientClipboard(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.15
    ) -> Bool {
        // Полная копия буфера (все элементы и типы), а не только строки.
        let previous = clipboardTransactions[pasteboard.name]
        let savedBackup = previous.flatMap { $0.changeCount == pasteboard.changeCount ? $0.backup : nil }
        let backup: [[NSPasteboard.PasteboardType: Data]] = savedBackup ?? (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }

        pasteboard.clearContents()
        let wroteText = pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount
        clipboardTransactions[pasteboard.name] = ClipboardTransaction(
            backup: backup, changeCount: ourChangeCount
        )
        guard wroteText, postKeyboardPaste() else {
            restoreClipboard(pasteboard, changeCount: ourChangeCount)
            return false
        }

        // A later paste inherits the original backup and owns its restoration.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, restoreDelay)))
            self?.restoreClipboard(pasteboard, changeCount: ourChangeCount)
        }

        return true
    }

    private static func defaultPostKeyboardPaste() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdKeyCode: CGKeyCode = 55 // kVK_Command
        let vKeyCode: CGKeyCode = 9 // ANSI virtual key code for 'V'
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKeyCode, keyDown: false) else {
            return false
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Private Helpers

    private func focusedElement(timeout: Float) -> (AXUIElement, NSRunningApplication?)? {
        if let app = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, timeout)
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef,
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let el = unsafeDowncast(focused, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(el, timeout)
                return (el, app)
            }
        }

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let el = unsafeDowncast(focused, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(el, timeout)
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            return (el, NSRunningApplication(processIdentifier: pid))
        }

        return nil
    }

    private func calculateCaretRect(el: AXUIElement, location: Int, fullText: String) -> CGRect? {
        // 1. Метод range(loc, 0)
        var zeroRange = CFRange(location: location, length: 0)
        if let rect = boundsForRange(el: el, range: &zeroRange) {
            return rect
        }

        // 2. Метод prevChar.maxX
        if location > 0 {
            var prevRange = CFRange(location: location - 1, length: 1)
            if let r = boundsForRange(el: el, range: &prevRange) {
                return CGRect(x: r.maxX, y: r.minY, width: 2, height: r.height)
            }
        }

        // 3. Метод nextChar.minX
        let ns = fullText as NSString
        if location < ns.length {
            var nextRange = CFRange(location: location, length: 1)
            if let r = boundsForRange(el: el, range: &nextRange) {
                return CGRect(x: r.minX, y: r.minY, width: 2, height: r.height)
            }
        }

        return nil
    }

    private func boundsForRange(el: AXUIElement, range: inout CFRange) -> CGRect? {
        guard let p = AXValueCreate(.cfRange, &range) else { return nil }
        var outRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            p,
            &outRef
        )
        guard err == .success,
              let out = outRef,
              CFGetTypeID(out) == AXValueGetTypeID() else {
            return nil
        }

        let axVal = unsafeDowncast(out, to: AXValue.self)
        guard AXValueGetType(axVal) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axVal, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    internal func convertAXToCocoa(axRect: CGRect, primaryScreenHeight: CGFloat? = nil) -> CGRect {
        // Главный экран NSScreen определяет начало глобальной системы координат (0,0 слева внизу)
        guard let primaryHeight = primaryScreenHeight ?? NSScreen.screens.first?.frame.height else {
            return axRect
        }
        let cocoaY = primaryHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.size.width, height: axRect.size.height)
    }
}
