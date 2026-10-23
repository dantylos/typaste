import AppKit
import ApplicationServices
import XCTest
@testable import LocalType

@MainActor
final class AXAdapterIntegrationTests: XCTestCase {

    func testSliceTextUTF16WithCyrillicEmojiAndSelection() {
        let text = "Привет 👋🏽 мир"
        let ns = text as NSString
        // "Привет " is 7 UTF-16 code units; "👋🏽" is 4 UTF-16 code units (2 surrogate pairs); " мир" is 4 UTF-16 code units.
        XCTAssertEqual(ns.length, 15)

        // Caret right after emoji (offset 11, length 0)
        let afterEmoji = AXAdapter.sliceText(text, selectedRange: CFRange(location: 11, length: 0))
        XCTAssertEqual(afterEmoji?.before, "Привет 👋🏽")
        XCTAssertEqual(afterEmoji?.after, " мир")

        // Selection covering the emoji (offset 7, length 4)
        let selectedEmoji = AXAdapter.sliceText(text, selectedRange: CFRange(location: 7, length: 4))
        XCTAssertEqual(selectedEmoji?.before, "Привет ")
        XCTAssertEqual(selectedEmoji?.after, " мир")

        // Out-of-bounds range returns nil safely
        XCTAssertNil(AXAdapter.sliceText(text, selectedRange: CFRange(location: -1, length: 0)))
        XCTAssertNil(AXAdapter.sliceText(text, selectedRange: CFRange(location: 99, length: 0)))
    }

    func testTier1InsertSuccessSkipsFallback() {
        let dummyElement = AXUIElementCreateSystemWide()
        var fallbackCalled = false

        let ok = AXAdapter.shared.insert(
            text: " world",
            into: dummyElement,
            axSetSelectedText: { _, _ in .success },
            axCopyValue: { _ in "Hello" },
            fallbackPaste: { _ in
                fallbackCalled = true
                return true
            }
        )

        XCTAssertTrue(ok)
        XCTAssertFalse(fallbackCalled, "Tier 2 clipboard fallback must not run when Tier 1 returns .success")
    }

    func testTier1FalseNegativeErrorWithMutatedValueSkipsFallback() {
        let dummyElement = AXUIElementCreateSystemWide()
        var currentText = "Привет"
        var fallbackCalled = false

        // Simulate Telegram macOS: AXUIElementSetAttributeValue mutates the text but returns -25200 (.failure)
        let ok = AXAdapter.shared.insert(
            text: " мир",
            into: dummyElement,
            axSetSelectedText: { _, inserted in
                currentText += inserted
                return .failure
            },
            axCopyValue: { _ in currentText },
            fallbackPaste: { _ in
                fallbackCalled = true
                return true
            }
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(currentText, "Привет мир")
        XCTAssertFalse(fallbackCalled, "Tier 2 fallback must be skipped when AXValue already changed despite -25200")
    }

    func testTier1TrueFailureInvokesTier2Fallback() {
        let dummyElement = AXUIElementCreateSystemWide()
        var fallbackText: String?

        let ok = AXAdapter.shared.insert(
            text: " продолжение",
            into: dummyElement,
            axSetSelectedText: { _, _ in .failure },
            axCopyValue: { _ in "Неизменный текст" },
            fallbackPaste: { str in
                fallbackText = str
                return true
            }
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(fallbackText, " продолжение")
    }

    func testTransientClipboardPreservesAndRestoresMultiItemPasteboard() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        let customType = NSPasteboard.PasteboardType("com.localtype.custom-test-type")
        let customData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let originalItem = NSPasteboardItem()
        originalItem.setString("Original clipboard text", forType: .string)
        originalItem.setData(customData, forType: customType)
        pb.clearContents()
        pb.writeObjects([originalItem])

        let originalPost = AXAdapter.shared.postKeyboardPaste
        defer { AXAdapter.shared.postKeyboardPaste = originalPost }

        var pastedDuringCallback: String?
        AXAdapter.shared.postKeyboardPaste = {
            pastedDuringCallback = pb.string(forType: .string)
            return true
        }

        let ok = AXAdapter.shared.insertViaTransientClipboard(
            "Transient suggestion",
            pasteboard: pb,
            restoreDelay: 0.05
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(pastedDuringCallback, "Transient suggestion")

        // Wait for restoration (50ms + margin)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(pb.string(forType: .string), "Original clipboard text")
        XCTAssertEqual(pb.data(forType: customType), customData)
    }

    func testTransientClipboardDoesNotOverwriteUserClipboardModification() async {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        pb.clearContents()
        pb.setString("Initial content", forType: .string)

        let originalPost = AXAdapter.shared.postKeyboardPaste
        defer { AXAdapter.shared.postKeyboardPaste = originalPost }
        AXAdapter.shared.postKeyboardPaste = { true }

        let ok = AXAdapter.shared.insertViaTransientClipboard(
            "Transient suggestion",
            pasteboard: pb,
            restoreDelay: 0.06
        )
        XCTAssertTrue(ok)

        // Simulate user copying something new before restoreDelay fires
        pb.clearContents()
        pb.setString("User newly copied text", forType: .string)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(pb.string(forType: .string), "User newly copied text")
    }

    func testConvertAXToCocoaCoordinateFlip() {
        // Primary screen height = 1080; AX rect at (x: 150, y: 200, width: 2, height: 20) from top-left
        let axRect = CGRect(x: 150, y: 200, width: 2, height: 20)
        let cocoaRect = AXAdapter.shared.convertAXToCocoa(axRect: axRect, primaryScreenHeight: 1080)

        XCTAssertEqual(cocoaRect.origin.x, 150)
        XCTAssertEqual(cocoaRect.origin.y, 1080 - 200 - 20)
        XCTAssertEqual(cocoaRect.width, 2)
        XCTAssertEqual(cocoaRect.height, 20)
    }
}
