// ═══════════════════════════════════════════════════════════════════
// 主视图（布局、添加任务、导出、主题切换）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var newTaskTitle = ""
    @State private var searchText = ""
    @State private var showThemePicker = false
    @State private var showExportMenu = false
    @State private var showShortcutsPanel = false
    @State private var showSearchBar = false
    @State private var toastVisible = false
    @State private var toastText = ""
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

                // iCloud 同步状态指示
                HStack(spacing: 2) {
                if state.iCloudAvailable {
                    Image(systemName: "checkmark.icloud")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.green.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .help("数据通过 iCloud Drive 自动同步")
                }

                // 导出按钮
                Button(action: { showExportMenu.toggle() }) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(theme.t3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showExportMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Button(action: { state.copyToClipboard(); showExportMenu = false; flashToast("已复制到剪贴板") }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.clipboard").frame(width: 16)
                                Text("复制到剪贴板")
                            }.font(.system(size: 13)).foregroundColor(theme.t1)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
                        }.buttonStyle(.plain)
                        Button(action: { showExportMenu = false; exportAsImage(style: .desktop) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "desktopcomputer").frame(width: 16)
                                Text("导出桌面版图片")
                            }.font(.system(size: 13)).foregroundColor(theme.t1)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
                        }.buttonStyle(.plain)
                        Button(action: { showExportMenu = false; exportAsImage(style: .mobile) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "iphone").frame(width: 16)
                                Text("导出手机版图片")
                            }.font(.system(size: 13)).foregroundColor(theme.t1)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
                        }.buttonStyle(.plain)
                        Divider().padding(.vertical, 2)
                        Button(action: { showExportMenu = false; state.addToCalendar { count, err in flashToast(err ?? "已添加 \(count) 条日程") } }) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar.badge.plus").frame(width: 16)
                                Text("添加到日历")
                            }.font(.system(size: 13)).foregroundColor(theme.t1)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
                        }.buttonStyle(.plain)
                        Button(action: { showExportMenu = false; state.removeFromCalendar { count, err in flashToast(err ?? "已删除 \(count) 条日程") } }) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar.badge.minus").frame(width: 16)
                                Text("从日历删除")
                            }.font(.system(size: 13)).foregroundColor(theme.red)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }.padding(6).frame(width: 180)
                }

                // 主题切换按钮
                Button(action: { showThemePicker.toggle() }) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(theme.t3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showThemePicker) { ThemePickerView().environmentObject(state) }

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
                        Text("快捷键").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.t1)
                            .padding(.bottom, 4)
                        shortcutRow("⌘ N", "新建任务")
                        shortcutRow("⌘ F", "搜索任务")
                        shortcutRow("⇧⌘ C", "复制到剪贴板")
                        shortcutRow("⌘ E", "导出图片")
                        shortcutRow("⇧⌘ S", "同步到日历")
                        shortcutRow("⌘ /", "快捷键一览")
                        Divider().padding(.vertical, 2)
                        shortcutRow("Enter", "提交输入")
                        shortcutRow("Esc", "取消/退出编辑")
                        shortcutRow("双击标题", "编辑任务名称")
                    }.padding(12).frame(width: 200)
                }
                }
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 10)

            Rectangle().fill(theme.border.opacity(0.15)).frame(height: 0.5)

            // ── 搜索栏 & 输入框容器 ──
            VStack(spacing: 8) {
                // 搜索栏（Cmd+F 触发）
                if showSearchBar {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(searchFocused ? theme.accent : theme.t3)
                        ZStack(alignment: .leading) {
                            if searchText.isEmpty {
                                Text("搜索任务...")
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

                // 添加任务输入框
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(addTaskFocused || !newTaskTitle.isEmpty ? theme.accent : theme.t3)
                    ZStack(alignment: .leading) {
                        if newTaskTitle.isEmpty {
                            Text("添加任务...")
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
                state.addToCalendar { count, err in flashToast(err ?? "已添加 \(count) 条日程") }
                state.triggerCalendarSync = false
            }
        }
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
        .alert("保存失败", isPresented: Binding(
            get: { state.saveError != nil },
            set: { if !$0 { state.saveError = nil } }
        )) {
            Button("确定") { state.saveError = nil }
        } message: {
            Text(state.saveError ?? "")
        }
        .animation(.appSpring, value: state.themeId)
        .preferredColorScheme(state.themeId == "auto" ? nil : (state.themeId == "paper" ? .light : .dark))
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
        return "\(s.tasks.count) 任务 · \(active) 进行中 · \(done)/\(total) 完成"
    }

    /// 提交新任务输入
    func submitNewTask() {
        let t = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.addTask(title: t); newTaskTitle = ""
    }

    /// 显示底部 Toast 提示（2秒后自动消失）
    func flashToast(_ msg: String) {
        toastText = msg
        withAnimation(.spring(response: 0.3)) { toastVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeOut(duration: 0.3)) { toastVisible = false }
        }
    }

    /// 导出当前分区为 PNG 图片（离屏窗口 + cacheDisplay Retina 渲染）
    func exportAsImage(style: ExportCardView.ExportStyle = .desktop) {
        guard let sec = state.activeSection else { return }
        let exportView = ExportCardView(section: sec, theme: state.theme, style: style)
        let hostingView = NSHostingView(rootView: exportView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // 挂到离屏窗口，继承屏幕 Retina backing scale
        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: fittingSize.width, height: fittingSize.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        offscreenWindow.contentView = hostingView
        offscreenWindow.orderBack(nil)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.display()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            offscreenWindow.orderOut(nil)
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        offscreenWindow.orderOut(nil)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "进度条-\(sec.name).png"
        if panel.runModal() == .OK, let url = panel.url,
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            flashToast("已导出为图片")
        }
    }
}
