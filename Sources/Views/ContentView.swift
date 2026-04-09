// ═══════════════════════════════════════════════════════════════════
// 主视图（布局、添加任务、导出、主题切换）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater: UpdateChecker
    @State private var newTaskTitle = ""
    @State private var searchText = ""
    @State private var showThemePicker = false
    @State private var showExportMenu = false
    @State private var showShortcutsPanel = false
    @State private var showSearchBar = false
    @State private var toastVisible = false
    @State private var toastText = ""
    @State private var toastWorkItem: DispatchWorkItem?
    @FocusState private var addTaskFocused: Bool
    @FocusState private var searchFocused: Bool

    var theme: ThemeColors { state.theme }
    var section: TaskSection? { state.activeSection }

    var body: some View {
        VStack(spacing: 0) {
            // ── 分区标签栏 ──
            SectionTabBar().environmentObject(state)
                .padding(.top, 8).padding(.bottom, 6)

            Rectangle().fill(theme.border.opacity(0.15)).frame(height: 0.5)

            // ── 页面头部 ──
            headerToolbar

            Rectangle().fill(theme.border.opacity(0.15)).frame(height: 0.5)

            // ── 搜索栏 & 输入框容器 ──
            VStack(spacing: 8) {
                if showSearchBar { searchBar }

                // 添加任务输入框
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(addTaskFocused || !newTaskTitle.isEmpty ? theme.accent : theme.t3)
                    ZStack(alignment: .leading) {
                        if newTaskTitle.isEmpty {
                            Text(L("task.add_placeholder"))
                                .font(.system(size: 14))
                                .foregroundColor(addTaskFocused ? theme.t3.opacity(0.3) : theme.t3)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $newTaskTitle)
                            .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(theme.t1)
                            .focused($addTaskFocused)
                            .onSubmit { submitNewTask() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(theme.surface.opacity(0.6)).cornerRadius(8)
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)

            // ── 任务列表 ──
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let s = section {
                        let filtered = searchText.isEmpty ? s.tasks : s.tasks.filter {
                            $0.title.localizedCaseInsensitiveContains(searchText) ||
                            $0.logs.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
                        }
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, task in
                            TaskRowView(task: task, index: i).environmentObject(state)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.97).combined(with: .opacity),
                                    removal: .scale(scale: 0.97).combined(with: .opacity)))
                        }
                    }
                    ArchiveSectionView().environmentObject(state).padding(.top, 12)
                }
                .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4)
            }
        }
        .onChange(of: state.focusNewTask) { _, focus in
            if focus { addTaskFocused = true; state.focusNewTask = false }
        }
        .onChange(of: state.focusSearch) { _, focus in
            if focus {
                showSearchBar = true
                state.focusSearch = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
            }
        }
        .onChange(of: state.showShortcuts) { _, show in
            if show { showShortcutsPanel = true; state.showShortcuts = false }
        }
        .onChange(of: state.triggerExport) { _, fire in
            if fire { exportAsImage(style: .desktop); state.triggerExport = false }
        }
        .onChange(of: state.triggerCalendarSync) { _, fire in
            if fire {
                state.addToCalendar { count, err in flashToast(err ?? L("toast.calendar_synced_%d", count)) }
                state.triggerCalendarSync = false
            }
        }
        .onAppear { updater.checkOnLaunchIfNeeded() }
        .background(theme.bg)
        .overlay(alignment: .bottom) {
            if toastVisible {
                Text(toastText)
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .alert(L("toast.save_failed"), isPresented: Binding(
            get: { state.saveError != nil },
            set: { if !$0 { state.saveError = nil } }
        )) {
            Button(L("ok")) { state.saveError = nil }
        } message: {
            Text(state.saveError ?? "")
        }
        .animation(.appSpring, value: state.themeId)
        .preferredColorScheme(state.themeId == "auto" ? nil : (state.themeId == "paper" ? .light : .dark))
    }

    // ── 页面头部工具栏 ──
    private var headerToolbar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(section?.name ?? "")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.t1)
            if let s = state.activeSection {
                Text("  " + sectionSummary(s))
                    .font(.system(size: 12))
                    .foregroundColor(theme.t3)
                    .padding(.bottom, 1)
            }
            Spacer()

            HStack(spacing: 2) {
                if state.iCloudAvailable {
                    Image(systemName: "checkmark.icloud")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.green.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .help(L("icloud.synced"))
                }

                // 日历同步按钮
                Button(action: {
                    if state.syncedTaskIds.isEmpty {
                        state.addToCalendar { count, err in flashToast(err ?? L("toast.calendar_synced_%d", count)) }
                    } else {
                        state.removeFromCalendar { count, err in flashToast(err ?? L("toast.calendar_removed_%d", count)) }
                    }
                }) {
                    Image(systemName: state.syncedTaskIds.isEmpty ? "calendar.badge.plus" : "calendar.badge.checkmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(state.syncedTaskIds.isEmpty ? theme.t3 : theme.green.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.syncedTaskIds.isEmpty ? L("export.sync_calendar") : L("export.unsync_calendar"))

                // 导出按钮
                Button(action: { showExportMenu.toggle() }) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(theme.t3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showExportMenu, arrowEdge: .bottom) { exportMenu }

                // 主题切换按钮
                Button(action: { showThemePicker.toggle() }) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(theme.t3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showThemePicker) { ThemePickerView().environmentObject(state) }

                // 更新提示按钮
                if updater.hasUpdate {
                    Button(action: {
                        SettingsWindowController.shared.open(state: state, updater: updater, tab: .update)
                    }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.accent)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("update.new_version_%@", updater.latestVersion ?? ""))
                }

                // 快捷键提示按钮
                Button(action: { showShortcutsPanel.toggle() }) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(theme.t3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showShortcutsPanel) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("shortcuts.title")).font(.system(size: 13, weight: .semibold)).foregroundColor(theme.t1)
                            .padding(.bottom, 4)
                        shortcutRow("⌘ N", L("menu.new_task"))
                        shortcutRow("⌘ F", L("menu.search_task"))
                        shortcutRow("⇧⌘ C", L("menu.copy_clipboard"))
                        shortcutRow("⌘ E", L("menu.export_image"))
                        shortcutRow("⇧⌘ S", L("menu.sync_calendar"))
                        shortcutRow("⌘ /", L("menu.shortcuts"))
                        Divider().padding(.vertical, 2)
                        shortcutRow("Enter", L("shortcuts.submit"))
                        shortcutRow("Esc", L("shortcuts.cancel_edit"))
                        shortcutRow(L("shortcuts.double_click"), L("shortcuts.edit_title"))
                    }.padding(12).frame(width: 200)
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 10)
    }

    // ── 搜索栏 ──
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(searchFocused ? theme.accent : theme.t3)
            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text(L("task.search_placeholder"))
                        .font(.system(size: 14))
                        .foregroundColor(searchFocused ? theme.t3.opacity(0.3) : theme.t3)
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(theme.t1)
                    .focused($searchFocused)
                    .onExitCommand { searchText = ""; showSearchBar = false }
            }
            if !searchText.isEmpty {
                Button(action: { searchText = ""; showSearchBar = false }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(theme.t3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.surface.opacity(0.6)).cornerRadius(8)
    }

    // ── 导出菜单 ──
    private var exportMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: { state.copyToClipboard(); showExportMenu = false; flashToast(L("toast.copied")) }) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").frame(width: 16)
                    Text(L("export.copy_clipboard"))
                }.font(.system(size: 13)).foregroundColor(theme.t1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
            }.buttonStyle(.plain)
            Button(action: { showExportMenu = false; exportAsImage(style: .desktop) }) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").frame(width: 16)
                    Text(L("export.desktop_image"))
                }.font(.system(size: 13)).foregroundColor(theme.t1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
            }.buttonStyle(.plain)
            Button(action: { showExportMenu = false; exportAsImage(style: .mobile) }) {
                HStack(spacing: 8) {
                    Image(systemName: "iphone").frame(width: 16)
                    Text(L("export.mobile_image"))
                }.font(.system(size: 13)).foregroundColor(theme.t1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
            }.buttonStyle(.plain)
        }.padding(6).frame(width: 180)
    }

    /// 快捷键行
    @ViewBuilder
    func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(desc).font(.system(size: 12)).foregroundColor(theme.t2)
            Spacer()
            Text(key).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.t3)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(theme.surface).cornerRadius(4)
        }
    }

    /// 生成分区统计摘要
    func sectionSummary(_ s: TaskSection) -> String {
        let total = s.tasks.count + s.archived.count
        let done = s.tasks.filter { $0.status == .done }.count + s.archived.count
        let active = s.tasks.filter { $0.status == .inProgress || $0.status == .blocked }.count
        return L("task.summary_%d_%d_%d_%d", s.tasks.count, active, done, total)
    }

    /// 提交新任务输入
    func submitNewTask() {
        let t = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.addTask(title: t); newTaskTitle = ""
    }

    /// 显示底部 Toast 提示（2秒后自动消失，取消前一个 Toast）
    func flashToast(_ msg: String) {
        // 取消前一个 Toast 的自动消失
        toastWorkItem?.cancel()
        toastText = msg
        withAnimation(.spring(response: 0.3)) { toastVisible = true }
        let workItem = DispatchWorkItem { [self] in
            withAnimation(.easeOut(duration: 0.3)) { toastVisible = false }
        }
        toastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    /// 导出当前分区为 PNG 图片（离屏窗口 + cacheDisplay Retina 渲染）
    func exportAsImage(style: ExportCardView.ExportStyle = .desktop) {
        guard let sec = state.activeSection else { return }

        // autoreleasepool 确保离屏渲染资源及时释放
        let pngData: Data? = autoreleasepool {
            let exportView = ExportCardView(section: sec, theme: state.theme, style: style)
            let hostingView = NSHostingView(rootView: exportView)
            let fittingSize = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: fittingSize)

            let offscreenWindow = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: fittingSize.width, height: fittingSize.height),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            offscreenWindow.contentView = hostingView
            offscreenWindow.orderBack(nil)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.display()

            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                offscreenWindow.close()
                return nil
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            offscreenWindow.close()
            return rep.representation(using: .png, properties: [:])
        }

        guard let png = pngData else {
            flashToast(L("toast.export_fail_image"))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "\(L("about.name"))-\(sec.name).png"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try png.write(to: url)
                flashToast(L("toast.exported"))
            } catch {
                flashToast(L("toast.export_fail_%@", error.localizedDescription))
            }
        }
    }
}
