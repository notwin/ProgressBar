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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "设置"
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
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
        WindowGroup("进度条") {
            ContentView(state: state)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 680)
        .commands {
            // App Menu: 设置 + 检查更新
            CommandGroup(after: .appInfo) {
                Button("设置...") {
                    SettingsWindowController.shared.open(state: state, updater: updater)
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("检查更新...") {
                    updater.checkForUpdates()
                    SettingsWindowController.shared.open(state: state, updater: updater, tab: .update)
                }
            }
            // File: 只保留自定义功能
            CommandGroup(replacing: .newItem) {
                Button("新建任务") { state.focusNewTask = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("搜索任务") { state.focusSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("复制到剪贴板") { state.copyToClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("导出图片") { state.triggerExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("同步到日历") { state.triggerCalendarSync = true }
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
                Button("快捷键一览") { state.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("切换到分区 \(n)") { state.switchToSection(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
            }
        }
    }
}
