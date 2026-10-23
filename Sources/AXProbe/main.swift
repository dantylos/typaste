// AXProbe — шаг 0.3 (SPEC §7, §13): проба Accessibility в целевых полях.
//
// Режимы:
//   AXProbe watch  [--interval 1.0] [--show-text]
//   AXProbe once   [--delay 5] [--show-text]
//   AXProbe insert [--delay 5] [--text " LT тест👋🏽"] [--undo-wait 20]
//
// По умолчанию текст поля НЕ печатается и НЕ пишется на диск: только длины,
// диапазоны и результаты проверок. --show-text печатает хвост перед кареткой
// (только в терминал). Результаты: ProbeResults/ax-probe.jsonl (в .gitignore).

import AppKit
import ApplicationServices
import Foundation

// MARK: - AX helpers

@MainActor
enum AX {
    static let timeout: Float = 0.5  // не зависаем на замороженном процессе

    static func name(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(e.rawValue))"
        }
    }

    static func copy(_ el: AXUIElement, _ attr: String) -> (CFTypeRef?, AXError) {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &ref)
        return (ref, err)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        let (r, e) = copy(el, attr)
        guard e == .success else { return nil }
        return r as? String
    }

    static func int(_ el: AXUIElement, _ attr: String) -> Int? {
        let (r, e) = copy(el, attr)
        guard e == .success else { return nil }
        return (r as? NSNumber)?.intValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        let (r, e) = copy(el, attr)
        guard e == .success, let r, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(r, to: AXUIElement.self)
    }

    static func axValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(ref, to: AXValue.self)
    }

    static func range(_ el: AXUIElement, _ attr: String) -> CFRange? {
        let (r, e) = copy(el, attr)
        guard e == .success, let v = axValue(r), AXValueGetType(v) == .cfRange else { return nil }
        var out = CFRange()
        return AXValueGetValue(v, .cfRange, &out) ? out : nil
    }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        let (r, e) = copy(el, attr)
        guard e == .success, let v = axValue(r), AXValueGetType(v) == .cgPoint else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &out) ? out : nil
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        let (r, e) = copy(el, attr)
        guard e == .success, let v = axValue(r), AXValueGetType(v) == .cgSize else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(v, .cgSize, &out) ? out : nil
    }

    static func names(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyAttributeNames(el, &arr) == .success else { return [] }
        return (arr as? [String]) ?? []
    }

    static func paramNames(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(el, &arr) == .success else { return [] }
        return (arr as? [String]) ?? []
    }

    static func settable(_ el: AXUIElement, _ attr: String) -> Bool? {
        var b = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, attr as CFString, &b) == .success else { return nil }
        return b.boolValue
    }

    static func param(_ el: AXUIElement, _ attr: String, _ range: CFRange) -> (CFTypeRef?, AXError) {
        var r = range
        guard let p = AXValueCreate(.cfRange, &r) else { return (nil, .failure) }
        var out: CFTypeRef?
        let e = AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, p, &out)
        return (out, e)
    }

    static func boundsFor(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        let (r, e) = param(el, kAXBoundsForRangeParameterizedAttribute, range)
        guard e == .success, let v = axValue(r), AXValueGetType(v) == .cgRect else { return nil }
        var out = CGRect.zero
        guard AXValueGetValue(v, .cgRect, &out), out.height > 0 else { return nil }
        return out
    }
}

// MARK: - Focus

@MainActor
func focusedElement() -> (AXUIElement, NSRunningApplication?)? {
    if let app = NSWorkspace.shared.frontmostApplication {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, AX.timeout)
        if let f = AX.element(appEl, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(f, AX.timeout)
            return (f, app)
        }
    }
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, AX.timeout)
    if let f = AX.element(sys, kAXFocusedUIElementAttribute) {
        AXUIElementSetMessagingTimeout(f, AX.timeout)
        var pid: pid_t = 0
        AXUIElementGetPid(f, &pid)
        return (f, NSRunningApplication(processIdentifier: pid))
    }
    return nil
}

// MARK: - Snapshot

struct Snapshot: Codable {
    var timestamp: String
    var mode: String
    var bundleID: String?
    var appName: String?
    var pid: Int32
    var role: String?
    var subrole: String?
    var roleDescription: String?
    var domIdentifier: String?
    var rolePath: [String]
    var inWebArea: Bool
    var attributes: [String]
    var parameterizedAttributes: [String]
    var settableValue: Bool?
    var settableSelectedText: Bool?
    var settableSelectedTextRange: Bool?
    var valueReadable: Bool
    var valueLengthUTF16: Int?
    var numberOfCharacters: Int?
    var selectedRange: [Int]?
    var selectedTextLengthUTF16: Int?
    var utf16Check: String
    var insertionPointLine: Int?
    var fieldFrame: [Double]?
    var caretRect: [Double]?
    var caretMethod: String
    var caretOnScreen: Bool?
    var contextTail: String?
    var errors: [String: String]
}

func iso() -> String { ISO8601DateFormatter().string(from: Date()) }

func isHighSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDBFF).contains(u) }
func isLowSurrogate(_ u: UInt16) -> Bool { (0xDC00...0xDFFF).contains(u) }

@MainActor
func axScreenFrames() -> [CGRect] {
    // AX использует систему координат с началом в левом верхнем углу главного экрана.
    guard let primary = NSScreen.screens.first else { return [] }
    let h = primary.frame.height
    return NSScreen.screens.map { f in
        CGRect(x: f.frame.minX, y: h - f.frame.maxY, width: f.frame.width, height: f.frame.height)
    }
}

@MainActor
func caret(_ el: AXUIElement, loc: Int, value: String?) -> (CGRect?, String) {
    let u = value.map { Array($0.utf16) }
    if let r = AX.boundsFor(el, CFRange(location: loc, length: 0)) {
        return (r, "range(loc,0)")
    }
    if loc > 0 {
        var prevLen = 1
        if let u, loc - 1 < u.count, isLowSurrogate(u[loc - 1]), loc >= 2 { prevLen = 2 }
        if let r = AX.boundsFor(el, CFRange(location: loc - prevLen, length: prevLen)) {
            return (CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height), "prevChar.maxX")
        }
    }
    if let u, loc < u.count {
        let nextLen = isHighSurrogate(u[loc]) && loc + 1 < u.count ? 2 : 1
        if let r = AX.boundsFor(el, CFRange(location: loc, length: nextLen)) {
            return (CGRect(x: r.minX, y: r.minY, width: 0, height: r.height), "nextChar.minX")
        }
    }
    return (nil, "unavailable")
}

@MainActor
func utf16Check(_ el: AXUIElement, value: String?, sel: CFRange?) -> String {
    guard let value else { return "n/a: AXValue не читается" }
    guard let sel else { return "n/a: AXSelectedTextRange не читается" }
    let u = Array(value.utf16)
    let loc = sel.location, len = sel.length
    guard loc >= 0, len >= 0, loc + len <= u.count else {
        return "mismatch: диапазон \(loc),\(len) вне длины значения \(u.count)"
    }
    if loc > 0, loc < u.count, isLowSurrogate(u[loc]) {
        return "mismatch: каретка разрезает суррогатную пару (не UTF-16 или смещение)"
    }
    let ns = value as NSString
    if len > 0 {
        guard let selText = AX.string(el, kAXSelectedTextAttribute) else {
            return "partial: AXSelectedText не читается"
        }
        return ns.substring(with: NSRange(location: loc, length: len)) == selText
            ? "ok: selectedText совпадает с value[range]" : "mismatch: selectedText != value[range]"
    }
    guard loc > 0 else { return "n/a: каретка в позиции 0, поставьте её после текста" }
    let l = (loc >= 2 && isLowSurrogate(u[loc - 1])) ? 2 : min(2, loc)
    let (r, e) = AX.param(el, kAXStringForRangeParameterizedAttribute, CFRange(location: loc - l, length: l))
    guard e == .success, let s = r as? String else {
        return "partial: границы корректны, StringForRange недоступен (\(AX.name(e)))"
    }
    return s == ns.substring(with: NSRange(location: loc - l, length: l))
        ? "ok: StringForRange совпадает с value перед кареткой" : "mismatch: StringForRange != value перед кареткой"
}

@MainActor
func takeSnapshot(mode: String, showText: Bool) -> (Snapshot, AXUIElement)? {
    guard let (el, app) = focusedElement() else { return nil }
    var errors: [String: String] = [:]
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)

    var rolePath: [String] = []
    var cursor: AXUIElement? = AX.element(el, kAXParentAttribute)
    for _ in 0..<12 {
        guard let c = cursor else { break }
        rolePath.append(AX.string(c, kAXRoleAttribute) ?? "?")
        cursor = AX.element(c, kAXParentAttribute)
    }

    let (valueRef, valueErr) = AX.copy(el, kAXValueAttribute)
    let value = valueRef as? String
    if valueErr != .success { errors["AXValue"] = AX.name(valueErr) }
    let sel = AX.range(el, kAXSelectedTextRangeAttribute)
    if sel == nil { errors["AXSelectedTextRange"] = AX.name(AX.copy(el, kAXSelectedTextRangeAttribute).1) }

    var caretRect: CGRect?
    var caretMethod = "n/a: нет диапазона"
    if let sel {
        (caretRect, caretMethod) = caret(el, loc: sel.location, value: value)
    }
    let onScreen = caretRect.map { r in axScreenFrames().contains { $0.intersects(r.insetBy(dx: -1, dy: 0)) } }

    var fieldFrame: [Double]?
    if let p = AX.point(el, kAXPositionAttribute), let s = AX.size(el, kAXSizeAttribute) {
        fieldFrame = [p.x, p.y, s.width, s.height].map(Double.init)
    }

    var tail: String?
    if showText, let value, let sel, sel.location <= value.utf16.count {
        let ns = value as NSString
        let start = max(0, sel.location - 24)
        tail = ns.substring(with: NSRange(location: start, length: sel.location - start))
    }

    let snap = Snapshot(
        timestamp: iso(), mode: mode,
        bundleID: app?.bundleIdentifier, appName: app?.localizedName, pid: pid,
        role: AX.string(el, kAXRoleAttribute),
        subrole: AX.string(el, kAXSubroleAttribute),
        roleDescription: AX.string(el, kAXRoleDescriptionAttribute),
        domIdentifier: AX.string(el, "AXDOMIdentifier"),
        rolePath: rolePath,
        inWebArea: rolePath.contains("AXWebArea"),
        attributes: AX.names(el),
        parameterizedAttributes: AX.paramNames(el),
        settableValue: AX.settable(el, kAXValueAttribute),
        settableSelectedText: AX.settable(el, kAXSelectedTextAttribute),
        settableSelectedTextRange: AX.settable(el, kAXSelectedTextRangeAttribute),
        valueReadable: value != nil,
        valueLengthUTF16: value?.utf16.count,
        numberOfCharacters: AX.int(el, kAXNumberOfCharactersAttribute),
        selectedRange: sel.map { [$0.location, $0.length] },
        selectedTextLengthUTF16: AX.string(el, kAXSelectedTextAttribute)?.utf16.count,
        utf16Check: utf16Check(el, value: value, sel: sel),
        insertionPointLine: AX.int(el, kAXInsertionPointLineNumberAttribute),
        fieldFrame: fieldFrame,
        caretRect: caretRect.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) },
        caretMethod: caretMethod,
        caretOnScreen: onScreen,
        contextTail: nil,  // никогда не пишется на диск
        errors: errors
    )
    if let tail { print("  хвост перед кареткой: «\(tail)»") }
    return (snap, el)
}

// MARK: - Output

func appendJSONL<T: Encodable>(_ value: T) {
    let dir = URL(fileURLWithPath: "ProbeResults", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("ax-probe.jsonl")
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard var data = try? enc.encode(value) else { return }
    data.append(0x0A)
    if let h = try? FileHandle(forWritingTo: file) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: file)
    }
}

func fmt(_ b: Bool?) -> String { b.map { $0 ? "да" : "нет" } ?? "?" }

func printSnapshot(_ s: Snapshot) {
    print("""
    ── \(s.appName ?? "?") [\(s.bundleID ?? "?")] pid \(s.pid)
      роль: \(s.role ?? "?") / \(s.subrole ?? "-") (\(s.roleDescription ?? "-"))\(s.domIdentifier.map { " dom#\($0)" } ?? "")
      web: \(s.inWebArea ? "да" : "нет")  путь: \(s.rolePath.prefix(6).joined(separator: " ← "))
      AXValue читается: \(s.valueReadable ? "да" : "нет")  длина UTF-16: \(s.valueLengthUTF16.map(String.init) ?? "-")  NumberOfCharacters: \(s.numberOfCharacters.map(String.init) ?? "-")
      выделение: \(s.selectedRange.map { "\($0[0]),\($0[1])" } ?? "-")  строка: \(s.insertionPointLine.map(String.init) ?? "-")
      UTF-16: \(s.utf16Check)
      caret: \(s.caretRect.map { $0.map { String(format: "%.0f", $0) }.joined(separator: ",") } ?? "-") [\(s.caretMethod)] на экране: \(fmt(s.caretOnScreen))
      settable: value=\(fmt(s.settableValue)) selectedText=\(fmt(s.settableSelectedText)) range=\(fmt(s.settableSelectedTextRange))
      ошибки: \(s.errors.isEmpty ? "-" : s.errors.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
    """)
}

// MARK: - Insert + Undo

struct InsertResult: Codable {
    var timestamp: String
    var before: Snapshot
    var insertedLengthUTF16: Int
    var setError: String
    var valueChanged: Bool
    var lengthDeltaOK: Bool?
    var insertedAtCaret: Bool?
    var caretAfterOK: Bool?
    var caretAfter: [Int]?
    var undo: String
}

@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func countdown(_ seconds: Int, _ what: String) {
    print("Переключитесь в целевое поле. \(what) через:", terminator: "")
    for i in stride(from: seconds, to: 0, by: -1) {
        print(" \(i)", terminator: ""); fflush(stdout)
        pump(1)
    }
    print()
}

@MainActor
func runInsert(text: String, delay: Int, undoWait: Int) {
    countdown(delay, "Вставка")
    guard let (before, el) = takeSnapshot(mode: "insert-before", showText: false) else {
        print("Нет сфокусированного AX-элемента."); return
    }
    printSnapshot(before)
    if before.subrole == kAXSecureTextFieldSubrole || before.role == "AXSecureTextField" {
        print("Отказ: защищённое поле (пароль). Вставка не выполняется."); return
    }
    guard let sel = before.selectedRange else { print("Отказ: нет AXSelectedTextRange."); return }
    let beforeValue = AX.string(el, kAXValueAttribute)
    let n = text.utf16.count

    let err = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString)
    pump(0.4)

    let target = focusedElement()?.0 ?? el
    let afterValue = AX.string(target, kAXValueAttribute)
    let afterRange = AX.range(target, kAXSelectedTextRangeAttribute)
    var lengthOK: Bool?, atCaret: Bool?, caretOK: Bool?
    if let b = beforeValue, let a = afterValue {
        lengthOK = a.utf16.count == b.utf16.count - sel[1] + n
        let ns = a as NSString
        if sel[0] + n <= ns.length {
            atCaret = ns.substring(with: NSRange(location: sel[0], length: n)) == text
        }
    }
    if let r = afterRange { caretOK = r.location == sel[0] + n && r.length == 0 }

    print("""
      вставка: \(AX.name(err))  значение изменилось: \(fmt(beforeValue.map { $0 != afterValue }))
      длина +\(n) UTF-16: \(fmt(lengthOK))  текст на месте каретки: \(fmt(atCaret))  каретка после вставки: \(fmt(caretOK)) \(afterRange.map { "(\($0.location),\($0.length))" } ?? "")
    """)

    var undo = "не проверялось: AXValue не читается"
    if let beforeValue, beforeValue != afterValue {
        NSSound.beep()
        print("Нажмите Cmd+Z ОДИН раз в целевом приложении (ожидание \(undoWait) с)…")
        undo = "не отменено за \(undoWait) с"
        let deadline = Date().addingTimeInterval(TimeInterval(undoWait))
        var lastSeen = afterValue
        var states = 0
        while Date() < deadline {
            pump(0.2)
            let cur = focusedElement().flatMap { AX.string($0.0, kAXValueAttribute) }
            if cur != lastSeen { states += 1; lastSeen = cur }
            if cur == beforeValue {
                undo = states == 1 ? "ok: отменено одним шагом" : "ok: отменено, промежуточных состояний \(states)"
                break
            }
        }
        if !undo.hasPrefix("ok"), lastSeen != afterValue {
            undo = "partial: значение изменилось, но не вернулось к исходному"
        }
    }
    print("  Undo: \(undo)")

    appendJSONL(InsertResult(
        timestamp: iso(), before: before, insertedLengthUTF16: n, setError: AX.name(err),
        valueChanged: beforeValue != afterValue, lengthDeltaOK: lengthOK, insertedAtCaret: atCaret,
        caretAfterOK: caretOK, caretAfter: afterRange.map { [$0.location, $0.length] }, undo: undo))
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let mode = args.first ?? "watch"
let showText = args.contains("--show-text")

let trustOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
guard AXIsProcessTrustedWithOptions(trustOptions) else {
    print("""
    Нет разрешения Accessibility.
    Системные настройки → Конфиденциальность и безопасность → Универсальный доступ:
    включите приложение, из которого запускаете AXProbe (Terminal / iTerm / Antigravity),
    затем полностью перезапустите это приложение.
    """)
    exit(2)
}

switch mode {
case "watch":
    let interval = Double(opt("--interval") ?? "") ?? 1.0
    print("watch: печать при смене поля/каретки. Ctrl+C — выход. Лог: ProbeResults/ax-probe.jsonl")
    var lastKey = ""
    while true {
        if let (s, _) = takeSnapshot(mode: "watch", showText: false) {
            let key = "\(s.pid)|\(s.role ?? "")|\(s.fieldFrame ?? [])|\(s.selectedRange ?? [])|\(s.valueLengthUTF16 ?? -1)"
            if key != lastKey {
                lastKey = key
                if showText { _ = takeSnapshot(mode: "watch", showText: true) }
                printSnapshot(s)
                appendJSONL(s)
            }
        }
        pump(interval)
    }
case "once":
    countdown(Int(opt("--delay") ?? "") ?? 5, "Снимок")
    if let (s, _) = takeSnapshot(mode: "once", showText: showText) {
        printSnapshot(s); appendJSONL(s)
    } else {
        print("Нет сфокусированного AX-элемента.")
    }
case "insert":
    runInsert(
        text: opt("--text") ?? " LT тест👋🏽",
        delay: Int(opt("--delay") ?? "") ?? 5,
        undoWait: Int(opt("--undo-wait") ?? "") ?? 20)
default:
    print("Использование: AXProbe watch|once|insert [--delay N] [--interval S] [--text T] [--undo-wait N] [--show-text]")
    exit(64)
}
