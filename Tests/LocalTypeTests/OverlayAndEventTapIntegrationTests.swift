import AppKit
import ApplicationServices
import XCTest
@testable import LocalType

@MainActor
final class OverlayAndEventTapIntegrationTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            OverlayController.shared.hide()
            let tap = EventTapManager.shared
            tap.onTab = nil
            tap.onShiftTab = nil
            tap.onEscape = nil
            tap.onTyping = nil
        }
        try await super.tearDown()
    }

    func testOverlayShowUpdateAndHideLifecycle() {
        let overlay = OverlayController.shared
        overlay.hide()
        XCTAssertFalse(overlay.isVisible)
        XCTAssertNil(overlay.currentSuggestion)

        let caret = CGRect(x: 300, y: 400, width: 2, height: 18)
        overlay.show(suggestion: "первое второе третье", at: caret)

        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.currentSuggestion, "первое второе третье")
        XCTAssertEqual(overlay.displayedLabelText, "первое второе третье")
        XCTAssertNotNil(overlay.panelFrame)

        // Update with shorter remainder
        overlay.updateSuggestionText(" второе третье", at: CGRect(x: 360, y: 400, width: 2, height: 18))
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.currentSuggestion, " второе третье")
        XCTAssertEqual(overlay.displayedLabelText, " второе третье")

        overlay.hide()
        XCTAssertFalse(overlay.isVisible)
        XCTAssertNil(overlay.currentSuggestion)
    }

    func testOverlayScreenBoundsClampingAndFlipAboveBottomEdge() {
        let overlay = OverlayController.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        // Place caret at bottom-left corner so y - panelHeight - 6 < screen.frame.minY + 10
        let bottomCaret = CGRect(x: screen.frame.minX - 50, y: screen.frame.minY + 5, width: 2, height: 18)
        overlay.show(suggestion: "тест границ экрана", at: bottomCaret)

        guard let frame = overlay.panelFrame else {
            XCTFail("Expected non-nil panelFrame")
            return
        }

        // X should be clamped to at least screen.visibleFrame.minX + 10
        XCTAssertGreaterThanOrEqual(frame.origin.x, screen.visibleFrame.minX + 10)
        // Y should flip above the caret: bottomCaret.y + bottomCaret.height + 6
        XCTAssertEqual(frame.origin.y, max(screen.visibleFrame.minY + 10, bottomCaret.origin.y + bottomCaret.height + 6), accuracy: 0.5)

        overlay.hide()
    }

    func testEventTapKeyDownRoutingForTabShiftTabEscapeAndCommandShortcuts() {
        let tap = EventTapManager.shared

        var tabCount = 0
        var shiftTabCount = 0
        var escCount = 0
        var typedKeyCodes: [Int64] = []

        tap.onTab = {
            tabCount += 1
            return true
        }
        tap.onShiftTab = {
            shiftTabCount += 1
            return true
        }
        tap.onEscape = {
            escCount += 1
            return true
        }
        tap.onTyping = { code in
            typedKeyCodes.append(code)
        }

        // Plain Tab (48) -> swallowed
        XCTAssertTrue(tap.handleKeyDown(keyCode: 48, flags: []))
        XCTAssertEqual(tabCount, 1)

        // Shift+Tab (48 + .maskShift) -> swallowed
        XCTAssertTrue(tap.handleKeyDown(keyCode: 48, flags: .maskShift))
        XCTAssertEqual(shiftTabCount, 1)

        // Cmd+Tab (48 + .maskCommand) -> NOT intercepted, passes through to macOS app switcher
        XCTAssertFalse(tap.handleKeyDown(keyCode: 48, flags: .maskCommand))
        XCTAssertEqual(tabCount, 1)
        XCTAssertEqual(shiftTabCount, 1)

        // Plain Escape (53) -> swallowed
        XCTAssertTrue(tap.handleKeyDown(keyCode: 53, flags: []))
        XCTAssertEqual(escCount, 1)

        // Option+Escape (53 + .maskAlternate) -> passes through
        XCTAssertFalse(tap.handleKeyDown(keyCode: 53, flags: .maskAlternate))
        XCTAssertEqual(escCount, 1)

        // Regular typing ('a' = 0) -> triggers onTyping, does not swallow
        XCTAssertFalse(tap.handleKeyDown(keyCode: 0, flags: []))
        XCTAssertEqual(typedKeyCodes, [0])

        // Cmd+C (8 + .maskCommand) and Ctrl+A (0 + .maskControl) -> ignored by onTyping
        XCTAssertFalse(tap.handleKeyDown(keyCode: 8, flags: .maskCommand))
        XCTAssertFalse(tap.handleKeyDown(keyCode: 0, flags: .maskControl))
        XCTAssertEqual(typedKeyCodes, [0])
    }
}
