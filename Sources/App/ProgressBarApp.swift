// ═══════════════════════════════════════════════════════════════════
// 应用入口
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit

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
                ForEach(1...9, id: \.self) { n in
                    Button(L("menu.switch_section_%d", n)) { state.switchToSection(at: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
            }
        }
    }
}
