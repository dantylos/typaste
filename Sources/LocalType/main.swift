import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupStatusBar()

        Task {
            await AssistantCoordinator.shared.start()
        }
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "✦ LocalType"
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }

        let menu = NSMenu()

        let infoItem = NSMenuItem(
            title: "Модель: Qwen3-1.7B-Base 4-bit (Metal)",
            action: nil,
            keyEquivalent: ""
        )
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(
            title: "Автоподстановка активна",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: "s"
        )
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)
        self.toggleItem = toggle

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Завершить LocalType",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let newState = (sender.state == .on) ? NSControl.StateValue.off : NSControl.StateValue.on
        sender.state = newState
        AssistantCoordinator.shared.setEnabled(newState == .on)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// Запуск приложения AppKit
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
