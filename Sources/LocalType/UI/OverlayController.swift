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

        let effect = NSVisualEffectView(frame: p.contentView!.bounds)
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

        // Бейдж клавиш "⇥ Tab"
        let badge = NSTextField(labelWithString: "⇥ Tab")
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
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 20)
        ])

        self.panel = p
        self.suggestionLabel = label
        self.badgeLabel = badge
        self.visualEffectView = effect
    }

    public func show(suggestion: String, at caretCocoa: CGRect) {
        guard let panel, let label = suggestionLabel else { return }

        self.currentSuggestion = suggestion
        label.stringValue = suggestion

        // Расчет размера плашки в зависимости от длины текста
        let font = label.font ?? NSFont.systemFont(ofSize: 13)
        let textWidth = (suggestion as NSString).size(withAttributes: [.font: font]).width
        let panelWidth = min(max(textWidth + 80, 160), 450)
        let panelHeight: CGFloat = 36

        // Позиционирование рядом с кареткой
        var x = caretCocoa.origin.x + 4
        var y = caretCocoa.origin.y - panelHeight - 6

        // Проверяем границы экрана, чтобы плашка не вылезала за пределы
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caretCocoa.origin) }) ?? NSScreen.main {
            let maxX = screen.frame.maxX - panelWidth - 10
            let minX = screen.frame.minX + 10
            x = max(minX, min(x, maxX))

            if y < screen.frame.minY + 10 {
                // Если внизу нет места, показываем над кареткой
                y = caretCocoa.origin.y + caretCocoa.height + 6
            }
        }

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)

        if !isVisible {
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1.0
            }
            isVisible = true
        } else {
            panel.alphaValue = 1.0
        }
    }

    public func hide() {
        guard isVisible, let panel else { return }
        currentSuggestion = nil
        isVisible = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
