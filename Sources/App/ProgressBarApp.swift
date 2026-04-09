// ═══════════════════════════════════════════════════════════════════
// 应用入口
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit

@main
struct ProgressBarApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup(L("about.name")) {
            ContentView(state: state, updater: updater)
                .frame(minWidth: 600, minHeight: 400)
                .sheet(isPresented: $state.showSettings) {
                    SettingsView(updater: updater, selectedTab: state.settingsTab)
                        .environmentObject(state)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 780, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("menu.settings")) {
                    state.settingsTab = .appearance
                    state.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                Button(L("menu.check_update")) {
                    updater.checkForUpdates()
                    state.settingsTab = .update
                    state.showSettings = true
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
