import AppKit
import Foundation

@MainActor
public final class OverlayController {
    public static let shared = OverlayController()

    private var panel: NSPanel?
    private var suggestionLabel: NSTextField?
    private var badgeLabel: NSTextField?
    private var visualEffectView: NSVisualEffectView?

    public private(set) var isVisible: Bool = false
    public private(set) var currentSuggestion: String?

    internal var isPanelVisible: Bool { panel?.isVisible ?? false }
    internal var panelFrame: NSRect? { panel?.frame }
    internal var displayedLabelText: String? { suggestionLabel?.stringValue }

    private init() {
        setupPanel()
    }

    private func setupPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.alphaValue = 0.0

        let effect = NSVisualEffectView(frame: p.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // Текст подсказки
        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        // Бейдж клавиш "⇥ Слово  ⇧⇥ Всё"
        let badge = NSTextField(labelWithString: "⇥ Слово  ⇧⇥ Всё")
        badge.isEditable = false
        badge.isSelectable = false
        badge.isBezeled = false
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12)
        badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = NSColor.secondaryLabelColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(label)
        effect.addSubview(badge)
        p.contentView?.addSubview(effect)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            badge.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            badge.heightAnchor.constraint(equalToConstant: 20)
        ])

        self.panel = p
        self.suggestionLabel = label
        self.badgeLabel = badge
        self.visualEffectView = effect
    }

    private var lastCaretCocoa: CGRect?

    public func show(suggestion: String, at caretCocoa: CGRect) {
        guard let panel, let label = suggestionLabel else { return }

        self.lastCaretCocoa = caretCocoa
        self.currentSuggestion = suggestion
        label.stringValue = suggestion

        positionPanel(suggestion: suggestion, caret: caretCocoa)
        panel.alphaValue = 1
        panel.orderFront(nil)
        isVisible = true
    }

    public func updateSuggestionText(_ newSuggestion: String, at newCaret: CGRect? = nil) {
        guard isVisible, let label = suggestionLabel else { return }
        currentSuggestion = newSuggestion
        label.stringValue = newSuggestion
        if let newCaret { lastCaretCocoa = newCaret }
        guard let caret = lastCaretCocoa else { return }
        positionPanel(suggestion: newSuggestion, caret: caret)
    }

    private func positionPanel(suggestion: String, caret: CGRect) {
        guard let panel else { return }
        let font = suggestionLabel?.font ?? NSFont.systemFont(ofSize: 13)
        let textWidth = (suggestion as NSString).size(withAttributes: [.font: font]).width
        let panelWidth = min(max(textWidth + 145, 230), 550)
        let panelHeight: CGFloat = 36
        var x = caret.origin.x + 4
        var y = caret.origin.y - panelHeight - 6
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            x = max(bounds.minX + 10, min(x, bounds.maxX - panelWidth - 10))
            if y < bounds.minY + 10 {
                y = caret.maxY + 6
            }
            y = max(bounds.minY + 10, min(y, bounds.maxY - panelHeight - 10))
        }
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    public func hide() {
        guard isVisible, let panel else { return }
        currentSuggestion = nil
        isVisible = false

        // Immediate dismissal avoids an old animation hiding a newer suggestion.
        panel.alphaValue = 0
        panel.orderOut(nil)
    }
}
