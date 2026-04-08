// ═══════════════════════════════════════════════════════════════════
// 应用入口
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@main
/// 应用入口：配置窗口大小和标题
struct ProgressBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("进度条") {
            ContentView(state: state)
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建任务") { state.focusNewTask = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("搜索任务") { state.focusSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .importExport) {
                Button("复制到剪贴板") { state.copyToClipboard() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("导出图片") { state.triggerExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("同步到日历") { state.triggerCalendarSync = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("快捷键一览") { state.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}
