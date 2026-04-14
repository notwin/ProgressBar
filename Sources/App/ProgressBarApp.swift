// ═══════════════════════════════════════════════════════════════════
// 应用入口
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit

/// 拦截主窗口关闭：改为 orderOut，让 app 留在后台（菜单栏图标/热键继续工作）
@MainActor
final class MainWindowCloseHandler: NSObject, NSWindowDelegate {
    static let shared = MainWindowCloseHandler()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// SwiftUI → 抓取包裹它的 NSWindow，用于挂 delegate / 引用保存
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { onWindow(w) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// AppDelegate：禁止最后一个窗口关闭时退出 app
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// 集中做启动后初始化（主窗口拦截、菜单栏图标、悬浮窗注入 state、热键注册）
@MainActor
final class AppSetup {
    static let shared = AppSetup()
    private var didSetup = false
    weak var mainWindow: NSWindow?
    private var notificationObserver: NSObjectProtocol?

    func setup(state: AppState, updater: UpdateChecker, window: NSWindow) {
        mainWindow = window
        window.delegate = MainWindowCloseHandler.shared

        if didSetup { return }
        didSetup = true

        QuickInputWindowController.shared.configure(state: state)

        StatusBarController.shared.install { [weak self] in self?.mainWindow }

        // 注册默认热键（第 4 步之前做个 stub；等 Settings tab 录入时会覆盖）
        HotKeyManager.shared.register(config: HotKeyConfig.load()) {
            QuickInputWindowController.shared.toggle()
        }

        // 菜单栏 → 打开设置
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .openSettingsFromStatusBar, object: nil, queue: .main
        ) { [weak state, weak updater] _ in
            guard let state = state, let updater = updater else { return }
            Task { @MainActor in
                SettingsWindowController.shared.open(state: state, updater: updater)
            }
        }
    }
}

/// 设置窗口管理
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var keyMonitor: Any?

    func open(state: AppState, updater: UpdateChecker, tab: SettingsTab = .appearance) {
        if let w = window, w.isVisible {
            w.close()
        }
        let size = NSSize(width: 600, height: 350)
        let view = SettingsView(updater: updater, selectedTab: tab).environmentObject(state)
        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = L("settings.title")
        w.contentView = hostingView
        w.contentMinSize = size
        w.contentMaxSize = size
        w.restorationClass = nil
        w.invalidateRestorableState()
        w.isReleasedWhenClosed = false
        w.center()

        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
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
struct ProgressBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup(L("about.name")) {
            ContentView(state: state, updater: updater)
                .frame(minWidth: 600, minHeight: 400)
                .background(WindowAccessor { window in
                    AppSetup.shared.setup(state: state, updater: updater, window: window)
                })
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 680)
        .commands {
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
            CommandGroup(replacing: .newItem) {
                Button(L("menu.quick_input")) {
                    QuickInputWindowController.shared.configure(state: state)
                    QuickInputWindowController.shared.toggle()
                }
                // 不绑菜单快捷键，避免与悬浮窗内 ⌘⇧K 切分区冲突；呼出走 Carbon 全局热键
                Divider()
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
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {
                Button(L("menu.shortcuts")) { state.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
                Divider()
                Button(L("menu.prev_section")) { state.cycleSection(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button(L("menu.next_section")) { state.cycleSection(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button(L("menu.switch_section_%d", n)) { state.switchToSection(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
            }
        }
    }
}
