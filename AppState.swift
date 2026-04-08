// ═══════════════════════════════════════════════════════════════════
// 应用状态管理（数据持久化、iCloud 同步、CRUD 操作）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit
import EventKit

/// 全局应用状态：管理所有分区、任务、主题，负责数据持久化与 iCloud 同步
class AppState: ObservableObject {
    @Published var sections: [TaskSection] = []
    @Published var activeSectionId: String = ""
    @Published var themeId: String = "dark"
    @Published var iCloudAvailable: Bool = false
    @Published var focusNewTask: Bool = false
    @Published var focusSearch: Bool = false
    @Published var showShortcuts: Bool = false
    @Published var triggerExport: Bool = false
    @Published var triggerCalendarSync: Bool = false

    private var syncTimer: Timer?
    private var lastFileDate: Date?
    private var saveGeneration: UInt64 = 0

    var theme: ThemeColors {
        if themeId == "auto" {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return THEMES.first { $0.id == (isDark ? "obsidian" : "paper") } ?? THEMES[0]
        }
        return THEMES.first { $0.id == themeId } ?? THEMES[0]
    }
    var activeSection: TaskSection? { sections.first { $0.id == activeSectionId } }
    var activeSectionIndex: Int? { sections.firstIndex { $0.id == activeSectionId } }

    // ── 文件路径 ──

    static let localDir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ProgressBar")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let iCloudDir: URL? = {
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: cloud.path) else { return nil }
        let d = cloud.appendingPathComponent("ProgressBar")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    var dataURL: URL {
        (Self.iCloudDir ?? Self.localDir).appendingPathComponent("data.json")
    }

    // ── 初始化 ──

    private var appearanceObserver: NSObjectProtocol?

    init() {
        iCloudAvailable = Self.iCloudDir != nil
        load()
        // 只在已授权时刷新日历状态，不主动弹窗
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = status == .fullAccess
        } else {
            granted = status == .authorized
        }
        if granted { refreshCalendarSync() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkRemoteChanges()
        }
        // 监听系统外观变化，自动模式下刷新主题
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            if self?.themeId == "auto" { self?.objectWillChange.send() }
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
        guard let data = try? Data(contentsOf: dataURL) else {
// 尝试从旧位置迁移数据
            let oldURL = Self.localDir.appendingPathComponent("data.json")
            if let oldData = try? Data(contentsOf: oldURL),
               let oldTasks = try? JSONDecoder().decode([TaskItem].self, from: oldData) {
                migrateOldData(oldTasks)
            } else {
                createDefaults()
            }
            return
        }
// 尝试解析新格式
        if let appData = try? JSONDecoder().decode(AppData.self, from: data) {
            sections = appData.sections
            themeId = appData.themeId
            activeSectionId = appData.activeSectionId
        }
// 尝试解析旧格式（纯任务数组）
        else if let oldTasks = try? JSONDecoder().decode([TaskItem].self, from: data) {
            migrateOldData(oldTasks)
            return
        }
        else {
            // 数据损坏，备份后创建默认
            let backupURL = dataURL.deletingLastPathComponent()
                .appendingPathComponent("data.corrupt.\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backupURL)
            createDefaults(); return
        }

        if !sections.contains(where: { $0.id == activeSectionId }) {
            activeSectionId = sections.first?.id ?? ""
        }
        lastFileDate = fileModDate()
    }

    /// 从旧版单列表格式迁移到新版分区格式
    func migrateOldData(_ oldTasks: [TaskItem]) {
        var active: [TaskItem] = []
        var archived: [TaskItem] = []
        for var t in oldTasks {
            if t.status == .done {
                t.completedAt = "已迁移"
                archived.append(t)
            } else { active.append(t) }
        }
        let sec = TaskSection(id: generateID(), name: "默认", tasks: active, archived: archived)
        sections = [sec]
        activeSectionId = sec.id
// 迁移旧版主题设置
        let oldThemeURL = Self.localDir.appendingPathComponent("theme.txt")
        if let t = try? String(contentsOf: oldThemeURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            themeId = (t == "default") ? "dark" : (THEMES.contains { $0.id == t } ? t : "dark")
        }
        save()
    }

    /// 创建默认分区和示例任务
    func createDefaults() {
        let sec = TaskSection(id: generateID(), name: "默认", tasks: defaultTasks(), archived: [])
        sections = [sec]
        activeSectionId = sec.id
        themeId = "obsidian"
        save()
    }

    @Published var saveError: String?

    /// 将当前数据保存到磁盘（iCloud 可用时同时备份到本地）
    func save() {
        saveGeneration &+= 1
        let appData = AppData(sections: sections, themeId: themeId, activeSectionId: activeSectionId)
        do {
            let data = try JSONEncoder().encode(appData)
            try data.write(to: dataURL, options: .atomic)
            if Self.iCloudDir != nil {
                let local = Self.localDir.appendingPathComponent("data.json")
                try? data.write(to: local, options: .atomic)
            }
        } catch {
            saveError = "数据保存失败: \(error.localizedDescription)"
        }
        lastFileDate = fileModDate()
    }

    /// 获取数据文件的最后修改时间
    func fileModDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: dataURL.path)[.modificationDate] as? Date
    }

    /// 检查远程文件是否有更新（iCloud 同步用）
    func checkRemoteChanges() {
        let gen = saveGeneration
        guard let cur = fileModDate(), let last = lastFileDate, cur > last, gen == saveGeneration else { return }
        load()
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
    func defaultTasks() -> [TaskItem] {[
        TaskItem(id: generateID(), title: "媒体部三个月打平计划", status: .inProgress, deadline: "04.30",
            logs: [LogEntry(id: generateID(), date: "26.04.08", text: "已经和小刘沟通完，明天给我 70 万每月的收入计划")], completedAt: nil),
        TaskItem(id: generateID(), title: "铃木大伟的特定技能业务推进", status: .pending, deadline: "", logs: [], completedAt: nil),
        TaskItem(id: generateID(), title: "工藤的系统台账打通", status: .inProgress, deadline: "04.13",
            logs: [LogEntry(id: generateID(), date: "26.04.08", text: "已经和工藤沟通完，这周完成上期的开发打通需求")], completedAt: nil),
        TaskItem(id: generateID(), title: "办公室的全套布置（电脑、打印机、电话）", status: .pending, deadline: "", logs: [], completedAt: nil),
        TaskItem(id: generateID(), title: "神盾二期上线发布", status: .blocked, deadline: "04.30",
            logs: [LogEntry(id: generateID(), date: "26.04.08", text: "和技术沟通完，目前卡点是视频语音通话，正在寻找解决方案")], completedAt: nil),
    ]}

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
        let t = TaskItem(id: generateID(), title: title, status: .pending, deadline: "", logs: [], completedAt: nil)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { sections[i].tasks.insert(t, at: 0) }
        save()
    }

    /// 删除指定任务（同步移除日历事件）
    func deleteTask(_ taskId: String) {
        guard let i = activeSectionIndex else { return }
        removeCalendarEvent(taskId: taskId)
        withAnimation(.appSpring) { sections[i].tasks.removeAll { $0.id == taskId } }
        save()
    }

    /// 归档任务：设置完成时间戳，移入归档（同步移除日历事件）
    func completeTask(_ taskId: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        var task = sections[si].tasks[ti]
        removeCalendarEvent(taskId: taskId)
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
        removeCalendarEvent(taskId: taskId)
        sections[si].tasks[ti].deadline = dl; save()
        if !dl.isEmpty { syncTaskToCalendar(taskId: taskId, title: sections[si].tasks[ti].title, deadline: dl) }
    }

    /// 编辑任务标题（同步更新日历事件）
    func editTitle(_ taskId: String, _ title: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let deadline = sections[si].tasks[ti].deadline
        removeCalendarEvent(taskId: taskId)
        sections[si].tasks[ti].title = title; save()
        if !deadline.isEmpty { syncTaskToCalendar(taskId: taskId, title: title, deadline: deadline) }
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
    private static let blockedKeywords = ["卡点", "延迟", "阻塞", "等待", "卡住", "暂停", "blocked"]

    /// 为任务添加进展日志，并自动推断状态
    func addLog(_ taskId: String, text: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let log = LogEntry(id: generateID(), date: today(), text: text)
        withAnimation(.appSpring) {
            sections[si].tasks[ti].logs.append(log)
            // 自动状态推断：检测阻塞关键词 → 已阻塞；待开始有日志 → 进行中
            let lower = text.lowercased()
            if Self.blockedKeywords.contains(where: { lower.contains($0) }) {
                sections[si].tasks[ti].status = .blocked
            } else if sections[si].tasks[ti].status == .pending {
                sections[si].tasks[ti].status = .inProgress
            }
        }
        save()
    }

    /// 删除任务的某条进展日志
    func deleteLog(_ taskId: String, logId: String) {
        guard let si = activeSectionIndex,
              let ti = sections[si].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        withAnimation(.appSpring) { sections[si].tasks[ti].logs.removeAll { $0.id == logId } }
        save()
    }

    // ── 日历功能 ──

    private let eventStore = EKEventStore()
    private let calendarName = "进度条"

    /// 查找专属日历（不创建）
    func findCalendar() -> EKCalendar? {
        eventStore.calendars(for: .event).first(where: { $0.title == calendarName })
    }

    /// 查询专属日历在指定时间范围内的事件
    func calendarEvents(in cal: EKCalendar, from start: Date, to end: Date) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [cal])
        return eventStore.events(matching: predicate)
    }

    private let calendarTag = "progressbar:"

    /// 刷新已同步到日历的任务 ID 集合
    @Published var syncedTaskIds: Set<String> = []

    func refreshCalendarSync() {
        guard let cal = findCalendar() else { syncedTaskIds = []; return }
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: -3, to: now)!
        let end = Calendar.current.date(byAdding: .month, value: 6, to: now)!
        let events = calendarEvents(in: cal, from: start, to: end)
        syncedTaskIds = Set(events.compactMap { $0.notes }.filter { $0.hasPrefix(calendarTag) }.map { String($0.dropFirst(calendarTag.count)) })
    }

    /// 同步单个任务到日历（用任务 ID 标识，避免标题匹配误操作）
    func syncTaskToCalendar(taskId: String, title: String, deadline: String) {
        guard let cal = findCalendar() ?? getOrCreateCalendar(),
              let date = deadlineToDate(deadline) else { return }
        // 检查是否已存在
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let tag = calendarTag + taskId
        if calendarEvents(in: cal, from: dayStart, to: dayEnd).contains(where: { $0.notes == tag }) { return }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.isAllDay = true
        event.startDate = date
        event.endDate = date
        event.calendar = cal
        event.notes = tag
        try? eventStore.save(event, span: .thisEvent)
        refreshCalendarSync()
    }

    /// 从日历移除指定任务 ID 的事件
    func removeCalendarEvent(taskId: String) {
        guard let cal = findCalendar() else { return }
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: -3, to: now)!
        let end = Calendar.current.date(byAdding: .month, value: 6, to: now)!
        let tag = calendarTag + taskId
        for event in calendarEvents(in: cal, from: start, to: end) where event.notes == tag {
            try? eventStore.remove(event, span: .thisEvent)
        }
        refreshCalendarSync()
    }

    /// 获取或创建专属日历（紫色）
    func getOrCreateCalendar() -> EKCalendar? {
        // 先找已有的
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == calendarName }) {
            return existing
        }
        // 创建新日历
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = calendarName
        calendar.cgColor = CGColor(red: 0.55, green: 0.24, blue: 1.0, alpha: 1.0) // 紫色
        // 选择本地源或 iCloud 源
        if let source = eventStore.sources.first(where: { $0.sourceType == .calDAV }) ??
                        eventStore.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = source
        } else {
            return nil
        }
        do { try eventStore.saveCalendar(calendar, commit: true); return calendar } catch { return nil }
    }

    /// 请求日历权限
    func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// 将所有有截止日期的任务添加到系统日历
    func addToCalendar(completion: @escaping (Int, String?) -> Void) {
        requestCalendarAccess { [weak self] granted in
            guard granted else { completion(0, "请在系统设置中授权日历权限"); return }
            guard let self = self, let section = self.activeSection else { completion(0, nil); return }
            guard let cal = self.getOrCreateCalendar() else { completion(0, "无法创建日历"); return }
            let tasksWithDeadline = section.tasks.filter { !$0.deadline.isEmpty }
            var count = 0
            for task in tasksWithDeadline {
                guard let date = deadlineToDate(task.deadline) else { continue }
                let tag = self.calendarTag + task.id
                let dayStart = Calendar.current.startOfDay(for: date)
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
                if self.calendarEvents(in: cal, from: dayStart, to: dayEnd).contains(where: { $0.notes == tag }) { continue }

                let event = EKEvent(eventStore: self.eventStore)
                event.title = task.title
                event.notes = tag
                event.isAllDay = true
                event.startDate = date
                event.endDate = date
                event.calendar = cal
                do { try self.eventStore.save(event, span: .thisEvent); count += 1 } catch {}
            }
            self.refreshCalendarSync()
            completion(count, nil)
        }
    }

    /// 从系统日历删除所有「进度条」创建的事件
    func removeFromCalendar(completion: @escaping (Int, String?) -> Void) {
        requestCalendarAccess { [weak self] granted in
            guard granted else { completion(0, "请在系统设置中授权日历权限"); return }
            guard let self = self else { completion(0, nil); return }
            guard let cal = self.findCalendar() else { completion(0, "未找到进度条日历"); return }
            let now = Date()
            let start = Calendar.current.date(byAdding: .month, value: -3, to: now)!
            let end = Calendar.current.date(byAdding: .month, value: 6, to: now)!
            let events = self.calendarEvents(in: cal, from: start, to: end)
            var count = 0
            for event in events {
                do { try self.eventStore.remove(event, span: .thisEvent); count += 1 } catch {}
            }
            self.refreshCalendarSync()
            completion(count, nil)
        }
    }


    // ── 导出功能 ──

    /// 导出当前分区为纯文本格式
    func exportText() -> String {
        guard let section = activeSection else { return "" }
        let icons: [TaskStatus: String] = [.pending: "⚪", .inProgress: "🔵", .blocked: "🔴", .done: "✅"]
        var out = "进度条 · \(section.name)\n" + String(repeating: "─", count: 30) + "\n\n"
        for (i, t) in section.tasks.enumerated() {
            let icon = icons[t.status] ?? "○"
            let dl = t.deadline.isEmpty ? "" : "  → \(t.deadline)"
            out += "\(i+1). \(icon) \(t.title)\(dl)\n"
            for l in t.logs { out += "   \(l.date)  \(l.text)\n" }
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
