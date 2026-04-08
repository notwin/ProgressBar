// ═══════════════════════════════════════════════════════════════════
// 日历管理器（系统日历同步、事件 CRUD）
// ═══════════════════════════════════════════════════════════════════

import EventKit
import SwiftUI

@MainActor
class CalendarManager {
    private let eventStore = EKEventStore()
    private let calendarName = "进度条"
    private let calendarTag = "progressbar:"

    /// 日历搜索范围常量
    private static let searchRangeMonthsBefore = -3
    private static let searchRangeMonthsAfter = 6

    /// 已同步到日历的任务 ID 集合
    var syncedTaskIds: Set<String> = []

    /// 错误报告回调
    var onError: ((String) -> Void)?

    // ── 日历查找与创建 ──

    /// 查找专属日历（不创建）
    func findCalendar() -> EKCalendar? {
        eventStore.calendars(for: .event).first(where: { $0.title == calendarName })
    }

    /// 查询专属日历在指定时间范围内的事件
    func calendarEvents(in cal: EKCalendar, from start: Date, to end: Date) -> [EKEvent] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [cal])
        return eventStore.events(matching: predicate)
    }

    /// 获取搜索范围（前后固定月数）
    private func searchRange() -> (start: Date, end: Date) {
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: Self.searchRangeMonthsBefore, to: now)!
        let end = Calendar.current.date(byAdding: .month, value: Self.searchRangeMonthsAfter, to: now)!
        return (start, end)
    }

    /// 获取或创建专属日历（紫色）
    func getOrCreateCalendar() -> EKCalendar? {
        // 先找已有的
        if let existing = findCalendar() {
            return existing
        }
        // 创建新日历
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = calendarName
        calendar.cgColor = CGColor(red: 0.55, green: 0.24, blue: 1.0, alpha: 1.0)
        if let source = eventStore.sources.first(where: { $0.sourceType == .calDAV }) ??
                        eventStore.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = source
        } else {
            onError?("无法找到日历源")
            return nil
        }
        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            onError?("创建日历失败: \(error.localizedDescription)")
            return nil
        }
    }

    // ── 同步状态 ──

    /// 刷新已同步到日历的任务 ID 集合
    func refreshCalendarSync() {
        guard let cal = findCalendar() else { syncedTaskIds = []; return }
        let range = searchRange()
        let events = calendarEvents(in: cal, from: range.start, to: range.end)
        syncedTaskIds = Set(events.compactMap { $0.notes }
            .filter { $0.hasPrefix(calendarTag) }
            .map { String($0.dropFirst(calendarTag.count)) })
    }

    // ── 单任务同步 ──

    /// 同步单个任务到日历
    func syncTaskToCalendar(taskId: String, title: String, deadline: String) {
        guard let cal = findCalendar() ?? getOrCreateCalendar(),
              let date = deadlineToDate(deadline) else { return }
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
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            onError?("添加日历事件失败: \(error.localizedDescription)")
        }
        refreshCalendarSync()
    }

    /// 从日历移除指定任务 ID 的事件
    func removeCalendarEvent(taskId: String) {
        guard let cal = findCalendar() else { return }
        let range = searchRange()
        let tag = calendarTag + taskId
        for event in calendarEvents(in: cal, from: range.start, to: range.end) where event.notes == tag {
            do {
                try eventStore.remove(event, span: .thisEvent)
            } catch {
                onError?("删除日历事件失败: \(error.localizedDescription)")
            }
        }
        refreshCalendarSync()
    }

    // ── 权限 ──

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

    // ── 批量操作 ──

    /// 将所有有截止日期的任务添加到系统日历
    func addToCalendar(tasks: [TaskItem], completion: @escaping (Int, String?) -> Void) {
        requestCalendarAccess { [weak self] granted in
            guard granted else { completion(0, "请在系统设置中授权日历权限"); return }
            guard let self = self else { completion(0, nil); return }
            guard let cal = self.getOrCreateCalendar() else { completion(0, "无法创建日历"); return }
            let tasksWithDeadline = tasks.filter { !$0.deadline.isEmpty }
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
                do {
                    try self.eventStore.save(event, span: .thisEvent)
                    count += 1
                } catch {
                    self.onError?("添加日历事件失败: \(error.localizedDescription)")
                }
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
            let range = self.searchRange()
            let events = self.calendarEvents(in: cal, from: range.start, to: range.end)
            var count = 0
            for event in events {
                do {
                    try self.eventStore.remove(event, span: .thisEvent)
                    count += 1
                } catch {
                    self.onError?("删除日历事件失败: \(error.localizedDescription)")
                }
            }
            self.refreshCalendarSync()
            completion(count, nil)
        }
    }

    /// 初始化时检查并刷新日历状态
    func initializeIfAuthorized() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = status == .fullAccess
        } else {
            granted = status == .authorized
        }
        if granted { refreshCalendarSync() }
    }
}
