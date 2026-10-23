import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class EventTapManager {
    public static let shared = EventTapManager()

    /// Возвращает `true`, если `Tab` был обработан (поглотить нажатие).
    public var onTab: (() -> Bool)?
    /// Возвращает `true`, если `Shift+Tab` был обработан (поглотить нажатие).
    public var onShiftTab: (() -> Bool)?
    /// Возвращает `true`, если `Escape` был обработан (поглотить нажатие).
    public var onEscape: (() -> Bool)?
    /// Вызывается при обычном вводе с клавиатуры (для запуска debounce генерации).
    public var onTyping: ((Int64) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    public func start() -> Bool {
        if eventTap != nil { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

            // Сторожевой механизм (SPEC §8): если система отключила tap по таймауту, сразу включаем обратно
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            var swallow = false
            MainActor.assumeIsolated {
                swallow = manager.handleKeyDown(keyCode: keyCode, flags: flags)
            }

            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            NSLog("[EventTap] Failed to create CGEventTap (Accessibility / Input Monitoring permission needed)")
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[EventTap] Started successfully")
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Обрабатывает нажатие клавиши. Возвращает `true`, если событие нужно поглотить (не передавать приложению).
    internal func handleKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        // Tab (keyCode 48)
        if keyCode == 48 {
            let isShift = flags.contains(.maskShift)
            let hasOtherMods = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            if !hasOtherMods {
                if isShift {
                    if onShiftTab?() == true { return true }
                } else {
                    if onTab?() == true { return true }
                }
            }
            return false
        }

        // Escape (keyCode 53)
        if keyCode == 53 {
            let hasMods = !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
            if !hasMods {
                if onEscape?() == true { return true }
            }
            return false
        }

        // Игнорируем сочетания с Command / Control (например Cmd+C, Cmd+V, Cmd+Z)
        let isCmdOrCtrl = !flags.intersection([.maskCommand, .maskControl]).isEmpty
        if !isCmdOrCtrl {
            onTyping?(keyCode)
        }
        return false
    }
}
