// ═══════════════════════════════════════════════════════════════════
// 系统菜单栏图标（左键呼出悬浮窗；右键弹菜单）
// ═══════════════════════════════════════════════════════════════════

import AppKit

@MainActor
final class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?

    private init() {}

    func install(mainWindowProvider: @escaping () -> NSWindow?) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Progress")
            button.image?.isTemplate = true
            button.toolTip = L("statusbar.tooltip")
            button.target = self
            button.action = #selector(onClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        self.mainWindowProvider = mainWindowProvider
    }

    private var mainWindowProvider: (() -> NSWindow?)?

    @objc private func onClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu(on: sender)
        } else {
            QuickInputWindowController.shared.toggle()
        }
    }

    private func showMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()
        let openMain = NSMenuItem(title: L("statusbar.open_main"), action: #selector(openMainWindow), keyEquivalent: "")
        openMain.target = self
        menu.addItem(openMain)

        let quickInput = NSMenuItem(title: L("menu.quick_input"), action: #selector(openQuickInput), keyEquivalent: "")
        quickInput.target = self
        menu.addItem(quickInput)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("statusbar.open_settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("statusbar.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // 临时把 menu 绑到 statusItem 让系统弹出
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindowProvider?() {
            w.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openQuickInput() {
        QuickInputWindowController.shared.show()
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsFromStatusBar, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let openSettingsFromStatusBar = Notification.Name("openSettingsFromStatusBar")
    static let quickInputCycleSection = Notification.Name("quickInputCycleSection")
}
