// ═══════════════════════════════════════════════════════════════════
// 应用入口
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit

/// 管理设置窗口的单例（手动创建 NSWindow，绕过 Settings scene 在 swiftc 下的问题）
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func open(state: AppState, updater: UpdateChecker, tab: SettingsTab = .appearance) {
        if let w = window, w.isVisible {
            w.close()
        }
        let view = SettingsView(updater: updater, selectedTab: tab).environmentObject(state)
        let hostingView = NSHostingView(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = L("settings.title")
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        // 支持 ⌘W 关闭窗口
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu ??
           NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains(where: { $0.keyEquivalent == "n" }) ?? false })?.submenu {
            if !fileMenu.items.contains(where: { $0.keyEquivalent == "w" }) {
                fileMenu.addItem(NSMenuItem.separator())
                fileMenu.addItem(closeItem)
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

@main
/// 应用入口：配置窗口大小和标题
struct ProgressBarApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup(L("about.name")) {
            ContentView(state: state, updater: updater)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 680)
        .commands {
            // App Menu: 设置 + 检查更新
            CommandGroup(after: .appInfo) {
                Button(L("menu.settings")) {
                    SettingsWindowController.shared.open(state: state, updater: updater)
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(L("menu.check_update")) {
                    updater.checkForUpdates()
                    SettingsWindowController.shared.open(state: state, updater: updater, tab: .update)
                }
            }
            // File: 只保留自定义功能
            CommandGroup(replacing: .newItem) {
                Button(L("menu.new_task")) { state.focusNewTask = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button(L("menu.search_task")) { state.focusSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button(L("menu.copy_clipboard")) { state.copyToClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(L("menu.export_image")) { state.triggerExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button(L("menu.sync_calendar")) { state.triggerCalendarSync = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {}
            // Edit: 清空（TextField 自带系统编辑能力）
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
            // View: 清空
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
            // Help: 快捷键一览 + ⌘1~9 切换分区
            CommandGroup(replacing: .help) {
                Button(L("menu.shortcuts")) { state.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button(L("menu.switch_section_%d", n)) { state.switchToSection(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
            }
        }
    }
}
