import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
public final class EventTapManager {
    public static let shared = EventTapManager()

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public var onTab: (() -> Bool)?
    public var onEscape: (() -> Bool)?
    public var onTyping: ((CGKeyCode) -> Void)?

    private init() {}

    public func start() -> Bool {
        guard machPort == nil else { return true }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let observerPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observerPointer
        ) else {
            NSLog("[EventTapManager] Failed to create CGEventTap. Ensure Accessibility permissions are granted.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.machPort = tap
        self.runLoopSource = source
        NSLog("[EventTapManager] Event tap started successfully.")
        return true
    }

    public func stop() {
        if let tap = machPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            machPort = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    // MARK: - Event Handler

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = machPort {
                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("[EventTapManager] Watchdog: re-enabled event tap after timeout")
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Tab (keyCode 48)
        if keyCode == 48 {
            if let onTab = self.onTab, onTab() {
                // Событие поглощено: подсказка вставлена
                return nil
            }
        }

        // Escape (keyCode 53)
        if keyCode == 53 {
            if let onEscape = self.onEscape, onEscape() {
                // Событие поглощено: подсказка скрыта
                return nil
            }
        }

        // Любая другая клавиша
        self.onTyping?(keyCode)

        return Unmanaged.passRetained(event)
    }
}
