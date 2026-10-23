import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var infoItem: NSMenuItem?
    private var memoryItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupStatusBar()

        AssistantCoordinator.shared.onStatusChange = { [weak self] status in
            self?.infoItem?.title = "Qwen3-1.7B-Instruct 4-bit: \(status)"
        }

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
        menu.delegate = self

        let infoItem = NSMenuItem(
            title: "Модель: Qwen3-1.7B-Instruct 4-bit (Metal)",
            action: nil,
            keyEquivalent: ""
        )
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        self.infoItem = infoItem

        let memoryItem = NSMenuItem(
            title: "Личный словарь (SQLite): \(PersonalMemoryStore.shared.phraseCount()) фраз",
            action: nil,
            keyEquivalent: ""
        )
        memoryItem.isEnabled = false
        menu.addItem(memoryItem)
        self.memoryItem = memoryItem

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

        let clearMemoryItem = NSMenuItem(
            title: "Очистить личный словарь",
            action: #selector(clearMemory),
            keyEquivalent: ""
        )
        clearMemoryItem.target = self
        menu.addItem(clearMemoryItem)

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

    func menuWillOpen(_ menu: NSMenu) {
        let count = PersonalMemoryStore.shared.phraseCount()
        memoryItem?.title = "Личный словарь (SQLite): \(count) фраз"
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let newState = (sender.state == .on) ? NSControl.StateValue.off : NSControl.StateValue.on
        sender.state = newState
        AssistantCoordinator.shared.setEnabled(newState == .on)
    }

    @objc private func clearMemory() {
        PersonalMemoryStore.shared.clearAll()
        memoryItem?.title = "Личный словарь (SQLite): 0 фраз"
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
