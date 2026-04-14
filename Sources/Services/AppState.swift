// ═══════════════════════════════════════════════════════════════════
// 应用状态管理（数据持久化、iCloud 同步、CRUD 操作）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit
import EventKit

/// 全局应用状态：管理所有分区、任务、主题，负责数据持久化与 iCloud 同步
@MainActor
class AppState: ObservableObject {
    @Published var sections: [TaskSection] = []
    @Published var activeSectionId: String = ""
    @Published var themeId: String = "obsidian"
    @Published var iCloudAvailable: Bool = false
    @Published var focusNewTask: Bool = false
    @Published var focusSearch: Bool = false
    @Published var showShortcuts: Bool = false
    @Published var triggerExport: Bool = false
    @Published var triggerCalendarSync: Bool = false
    @Published var saveError: String?
    @Published var syncedTaskIds: Set<String> = []

    let calendarManager = CalendarManager()
    let persistence = PersistenceManager()
    private var syncTimer: Timer?

    var theme: ThemeColors {
        if themeId == "auto" {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return THEMES.first { $0.id == (isDark ? "obsidian" : "paper") } ?? THEMES[0]
        }
        return THEMES.first { $0.id == themeId } ?? THEMES[0]
    }
    var activeSection: TaskSection? { sections.first { $0.id == activeSectionId } }
    var activeSectionIndex: Int? { sections.firstIndex { $0.id == activeSectionId } }

    // ── 初始化 ──

    private var appearanceObserver: NSObjectProtocol?

    init() {
        // 连接错误报告
        calendarManager.onError = { [weak self] msg in self?.saveError = msg }
        persistence.onError = { [weak self] msg in self?.saveError = msg }

        iCloudAvailable = persistence.iCloudAvailable
        load()
        calendarManager.initializeIfAuthorized()
        syncedTaskIds = calendarManager.syncedTaskIds
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            let s = self
            Task { @MainActor in s?.checkRemoteChanges() }
        }
        // 监听系统外观变化，自动模式下刷新主题
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            let s = self
            Task { @MainActor in
                if s?.themeId == "auto" { s?.objectWillChange.send() }
            }
        }
    }

    deinit {
        syncTimer?.invalidate()
        if let obs = appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    // ── 数据持久化 ──

    /// 从磁盘加载数据，支持新旧格式自动迁移
    func load() {
        let result = persistence.load()
        switch result {
        case .loaded(var appData):
            // 迁移旧格式截止日期
            for si in appData.sections.indices {
                for ti in appData.sections[si].tasks.indices {
                    appData.sections[si].tasks[ti].deadline =
                        migrateDeadlineFormat(appData.sections[si].tasks[ti].deadline)
                }
            }
            sections = appData.sections
            themeId = appData.themeId
            activeSectionId = appData.activeSectionId
            if !sections.contains(where: { $0.id == activeSectionId }) {
                activeSectionId = sections.first?.id ?? ""
            }
        case .migrated(let oldTasks):
            migrateOldData(oldTasks)
        case .empty:
            createDefaults()
        case .corrupted(let data):
            persistence.backupCorruptedData(data)
            saveError = L("data.corrupted")
            createDefaults()
        }
    }

    /// 从旧版单列表格式迁移到新版分区格式
    func migrateOldData(_ oldTasks: [TaskItem]) {
        var active: [TaskItem] = []
        var archived: [TaskItem] = []
        for var t in oldTasks {
            // 迁移截止日期格式
            t.deadline = migrateDeadlineFormat(t.deadline)
            if t.status == .done {
                t.completedAt = L("default.migrated")
                archived.append(t)
            } else { active.append(t) }
        }
        let sec = TaskSection(id: generateID(), name: L("default.section"), tasks: active, archived: archived)
        sections = [sec]
        activeSectionId = sec.id
        // 迁移旧版主题设置
        if let t = persistence.readLegacyThemeId() {
            themeId = (t == "default") ? "obsidian" : (THEMES.contains { $0.id == t } ? t : "obsidian")
        }
        save()
    }

    /// 创建默认分区和示例任务
    func createDefaults() {
        let sec = TaskSection(id: generateID(), name: L("default.section"), tasks: defaultTasks(), archived: [])
        sections = [sec]
        activeSectionId = sec.id
        themeId = "obsidian"
        save()
    }

    /// 将当前数据保存到磁盘（iCloud 可用时同时备份到本地）
    func save() {
        let appData = AppData(sections: sections, themeId: themeId, activeSectionId: activeSectionId)
        persistence.save(appData: appData)
    }

    /// 检查远程文件是否有更新（iCloud 同步用）
    func checkRemoteChanges() {
        if persistence.hasRemoteChanges() { load() }
    }

    // ── 工具方法 ──

    func generateID() -> String {
        UUID().uuidString.lowercased()
    }

    /// 获取今天的日期字符串（格式：YY.MM.DD）
    func today() -> String {
        let d = Date(); let c = Calendar.current
        return String(format: "%02d.%02d.%02d", c.component(.year, from: d) % 100,
                       c.component(.month, from: d), c.component(.day, from: d))
    }

    /// 生成默认示例任务列表
    func defaultTasks() -> [TaskItem] {
        let date = today()
        return [
            TaskItem(id: generateID(), title: L("default.task1"), status: .done, deadline: "",
                logs: [LogEntry(id: generateID(), date: date, text: L("default.log1"))], completedAt: nil),
            TaskItem(id: generateID(), title: L("default.task2"), status: .inProgress, deadline: "",
                logs: [LogEntry(id: generateID(), date: date, text: L("default.log2"))], completedAt: nil),
            TaskItem(id: generateID(), title: L("default.task3"), status: .pending, deadline: "",
                logs: [], completedAt: nil),
        ]
    }

    // ── 分区操作 ──

    /// 新建分区
    func addSection(name: String) {
        let s = TaskSection(id: generateID(), name: name, tasks: [], archived: [])
        withAnimation(.appSpring) { sections.append(s); activeSectionId = s.id }
        save()
    }

    /// 重命名分区
    func renameSection(_ id: String, name: String) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[i].name = name; save()
    }

    /// 按索引切换分区（⌘1~⌘9）
    func switchToSection(at index: Int) {
        guard index >= 0, index < sections.count else { return }
        withAnimation(.appSpring) { activeSectionId = sections[index].id }
        save()
    }

    /// 循环切换到下一个/上一个分区（direction: +1 下一个，-1 上一个）
    func cycleSection(_ direction: Int) {
        guard !sections.isEmpty,
              let idx = sections.firstIndex(where: { $0.id == activeSectionId }) else { return }
        let next = ((idx + direction) % sections.count + sections.count) % sections.count
        switchToSection(at: next)
    }

    /// 删除分区
    func deleteSection(_ id: String) {
        withAnimation(.appSpring) {
            sections.removeAll { $0.id == id }
            if activeSectionId == id { activeSectionId = sections.first?.id ?? "" }
        }
        save()
    }

    // ── 任务操作 ──

    /// 添加新任务到当前分区
    func addTask(title: String) {
        guard let i = activeSectionIndex else { return }
        addTask(title: title, to: sections[i].id)
    }

    /// 添加新任务到指定分区（供悬浮窗跨分区添加）
    func addTask(title: String, to sectionId: String) {
        guard let i = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let t = TaskItem(id: generateID(), title: title, status: .pending, deadline: "", logs: [], completedAt: nil)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { sections[i].tasks.insert(t, at: 0) }
        save()
    }

    /// 删除指定任务（同步移除日历事件）
    func deleteTask(_ taskId: String) {
        guard let i = activeSectionIndex else { return }
        calendarManager.removeCalendarEvent(taskId: taskId)
        syncedTaskIds = calendarManager.syncedTaskIds
        withAnimation(.appSpring) { sections[i].tasks.removeAll { $0.id == taskId } }
        save()
    }

    /// 归档任务：设置完成时间戳，移入归档（同步移除日历事件）
    func completeTask(_ taskId: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        var task = sections[si].tasks[ti]
        calendarManager.removeCalendarEvent(taskId: taskId)
        syncedTaskIds = calendarManager.syncedTaskIds
        task.completedAt = today(); task.status = .done
        withAnimation(.appSlow) {
            sections[si].tasks.remove(at: ti)
            sections[si].archived.insert(task, at: 0)
        }
        save()
    }

    /// 恢复归档任务：清除完成时间，移回活跃列表
    func restoreTask(_ taskId: String) {
        guard let si = activeSectionIndex,
              let ai = sections[si].archived.firstIndex(where: { $0.id == taskId }) else { return }
        var task = sections[si].archived[ai]
        task.completedAt = nil; task.status = .pending
        withAnimation(.appSpring) {
            sections[si].archived.remove(at: ai)
            sections[si].tasks.append(task)
        }
        save()
    }

    /// 永久删除归档任务
    func deleteArchivedTask(_ taskId: String) {
        guard let si = activeSectionIndex else { return }
        withAnimation(.appSpring) { sections[si].archived.removeAll { $0.id == taskId } }
        save()
    }

    /// 设置任务状态（待开始/进行中/推进中）
    func setStatus(_ taskId: String, _ status: TaskStatus) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { sections[si].tasks[ti].status = status }
        save()
    }

    /// 设置任务截止日期（自动同步日历）
    func setDeadline(_ taskId: String, _ dl: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        calendarManager.removeCalendarEvent(taskId: taskId)
        sections[si].tasks[ti].deadline = dl; save()
        if !dl.isEmpty { calendarManager.syncTaskToCalendar(taskId: taskId, title: sections[si].tasks[ti].title, deadline: dl) }
        syncedTaskIds = calendarManager.syncedTaskIds
    }

    /// 编辑任务标题（同步更新日历事件）
    func editTitle(_ taskId: String, _ title: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let deadline = sections[si].tasks[ti].deadline
        calendarManager.removeCalendarEvent(taskId: taskId)
        sections[si].tasks[ti].title = title; save()
        if !deadline.isEmpty { calendarManager.syncTaskToCalendar(taskId: taskId, title: title, deadline: deadline) }
        syncedTaskIds = calendarManager.syncedTaskIds
    }

    /// 拖拽排序：将任务从 fromIndex 移动到 toIndex
    func reorderTask(fromId: String, toId: String) {
        guard let si = activeSectionIndex,
              let fromIdx = sections[si].tasks.firstIndex(where: { $0.id == fromId }),
              let toIdx = sections[si].tasks.firstIndex(where: { $0.id == toId }),
              fromIdx != toIdx else { return }
        withAnimation(.appSpring) {
            let task = sections[si].tasks.remove(at: fromIdx)
            sections[si].tasks.insert(task, at: toIdx)
        }
        save()
    }

    /// 阻塞关键词
    private static let blockedKeywords = ["卡点", "延迟", "阻塞", "等待", "卡住", "暂停", "blocked", "stuck", "waiting", "paused"]

    /// 为任务添加进展日志，并自动推断状态
    func addLog(_ taskId: String, text: String) {
        addLog(taskId, in: activeSectionId, text: text)
    }

    /// 给指定分区中的指定任务加进展（供悬浮窗跨分区操作）
    func addLog(_ taskId: String, in sectionId: String, text: String) {
        guard let si = sections.firstIndex(where: { $0.id == sectionId }),
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let log = LogEntry(id: generateID(), date: today(), text: text)
        withAnimation(.appSpring) {
            sections[si].tasks[ti].logs.append(log)
            sections[si].tasks[ti].logs.sort { $0.date < $1.date }
            let lower = text.lowercased()
            if Self.blockedKeywords.contains(where: { lower.contains($0) }) {
                sections[si].tasks[ti].status = .blocked
            } else if sections[si].tasks[ti].status == .pending {
                sections[si].tasks[ti].status = .inProgress
            }
        }
        save()
    }

    /// 修改日志日期并按日期排序
    func updateLogDate(_ taskId: String, logId: String, newDate: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }),
              let li = sections[si].tasks[ti].logs.firstIndex(where: { $0.id == logId }) else { return }
        sections[si].tasks[ti].logs[li].date = newDate
        sortLogs(taskId: taskId)
        save()
    }

    /// 按日期排序日志（旧→新）
    private func sortLogs(taskId: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        sections[si].tasks[ti].logs.sort { $0.date < $1.date }
    }

    /// 删除任务的某条进展日志
    func deleteLog(_ taskId: String, logId: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        withAnimation(.appSpring) { sections[si].tasks[ti].logs.removeAll { $0.id == logId } }
        save()
    }

    // ── 日历功能（委托给 CalendarManager）──

    /// 将所有有截止日期的任务添加到系统日历
    func addToCalendar(completion: @escaping (Int, String?) -> Void) {
        guard let section = activeSection else { completion(0, nil); return }
        calendarManager.addToCalendar(tasks: section.tasks) { [weak self] count, err in
            self?.syncedTaskIds = self?.calendarManager.syncedTaskIds ?? []
            completion(count, err)
        }
    }

    /// 从系统日历删除所有「进度条」创建的事件
    func removeFromCalendar(completion: @escaping (Int, String?) -> Void) {
        calendarManager.removeFromCalendar { [weak self] count, err in
            self?.syncedTaskIds = self?.calendarManager.syncedTaskIds ?? []
            completion(count, err)
        }
    }

    // ── 导出功能 ──

    /// 导出当前分区为纯文本格式
    func exportText() -> String {
        guard let section = activeSection else { return "" }
        let icons: [TaskStatus: String] = [.pending: "⏹️", .inProgress: "▶️", .blocked: "⏸️", .done: "✅"]
        let total = section.tasks.count
        let done = section.tasks.filter { $0.status == .done }.count
        let active = section.tasks.filter { $0.status == .inProgress || $0.status == .blocked }.count

        var out = "📊 \(section.name)  \(L("task.summary_%d_%d_%d_%d", total, active, done, total))\n\n"
        for (i, t) in section.tasks.enumerated() {
            let icon = icons[t.status] ?? "◻️"
            let dl = t.deadline.isEmpty ? "" : "  → \(deadlineDisplay(t.deadline))"
            out += "\(i+1). \(icon) \(t.title)\(dl)\n"
            for l in t.logs {
                let d = l.date.split(separator: ".").count == 3
                    ? l.date.split(separator: ".").dropFirst().joined(separator: ".")
                    : l.date
                out += "    \(d)  \(l.text)\n"
            }
            if !t.logs.isEmpty { out += "\n" }
        }
        return out
    }

    /// 将导出文本复制到系统剪贴板
    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText(), forType: .string)
    }
}
