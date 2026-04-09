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
    private var keyMonitor: Any?

    func open(state: AppState, updater: UpdateChecker, tab: SettingsTab = .appearance) {
        if let w = window, w.isVisible {
            w.close()
        }
        let width: CGFloat = 420
        let view = SettingsView(updater: updater, selectedTab: tab).environmentObject(state)
        let hostingView = NSHostingView(rootView: view)
        // 让 SwiftUI 计算最佳高度
        let fittingHeight = max(hostingView.fittingSize.height, 280)
        let size = NSSize(width: width, height: fittingHeight)
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = L("settings.title")
        w.contentView = hostingView
        w.contentMinSize = NSSize(width: width, height: 280)
        w.contentMaxSize = NSSize(width: width, height: fittingHeight)
        w.restorationClass = nil
        w.invalidateRestorableState()
        w.isReleasedWhenClosed = false
        w.center()

        // 清理旧的事件监视器
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }

        // ⌘W 关闭设置窗口
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak w] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                if w?.isKeyWindow == true {
                    w?.close()
                    return nil
                }
            }
            return event
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
