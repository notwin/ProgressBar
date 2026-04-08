// ═══════════════════════════════════════════════════════════════════
// 数据模型（日志、任务、分区、持久化结构）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct LogEntry: Identifiable, Codable, Equatable {
    var id: String
    var date: String
    var text: String
}

struct TaskItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var status: String       // pending, in_progress, blocked, done
    var deadline: String
    var logs: [LogEntry]
    var completedAt: String?
    var isDone: Bool { completedAt != nil }
}

struct TaskSection: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var tasks: [TaskItem]
    var archived: [TaskItem]
}

struct AppData: Codable {
    var sections: [TaskSection]
    var themeId: String
    var activeSectionId: String
}

// ═══════════════════════════════════════════════════════════════════
// 任务状态定义（待开始、进行中、推进中）
// ═══════════════════════════════════════════════════════════════════

struct StatusInfo {
    let icon: String
    let label: String
    let colorKey: String
}

let STATUS_OPTIONS: [(key: String, info: StatusInfo)] = [
    ("pending",     StatusInfo(icon: "circle",                      label: "待开始", colorKey: "t3")),
    ("in_progress", StatusInfo(icon: "circle.fill",                 label: "进行中", colorKey: "accent")),
    ("blocked",     StatusInfo(icon: "exclamationmark.circle.fill", label: "已阻塞", colorKey: "red")),
    ("done",        StatusInfo(icon: "checkmark.circle.fill",       label: "已完成", colorKey: "green")),
]

/// 根据状态 key 获取对应的图标、标签、颜色信息
func statusInfo(for key: String) -> StatusInfo {
    STATUS_OPTIONS.first(where: { $0.key == key })?.info ?? STATUS_OPTIONS[0].info
}

// ═══════════════════════════════════════════════════════════════════
// 全局动画常量
// ═══════════════════════════════════════════════════════════════════

extension Animation {
    static let appSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let appSlow   = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let appFast   = Animation.easeOut(duration: 0.12)
    static let appFade   = Animation.easeOut(duration: 0.15)
}

// ═══════════════════════════════════════════════════════════════════
// 日期工具函数
// ═══════════════════════════════════════════════════════════════════

/// 将 "MM.DD" 格式的截止日期字符串转为 Date（智能推断年份）
func deadlineToDate(_ dl: String) -> Date {
    let parts = dl.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 2 else { return Date() }
    let cal = Calendar.current
    let now = Date()
    let year = cal.component(.year, from: now)
    guard let date = cal.date(from: DateComponents(year: year, month: parts[0], day: parts[1])) else { return Date() }
    if let diff = cal.dateComponents([.month], from: date, to: now).month, diff > 6 {
        return cal.date(from: DateComponents(year: year + 1, month: parts[0], day: parts[1])) ?? date
    }
    return date
}

/// 将 Date 转为 "MM.DD" 格式字符串
func dateToDeadline(_ date: Date) -> String {
    let c = Calendar.current
    return String(format: "%02d.%02d", c.component(.month, from: date), c.component(.day, from: date))
}

/// 判断截止日期是否已过期
func isDeadlineOverdue(_ dl: String) -> Bool {
    guard !dl.isEmpty else { return false }
    return deadlineToDate(dl) < Calendar.current.startOfDay(for: Date())
}

/// 根据颜色 key 和当前主题返回对应 Color
func themeColor(for key: String, _ theme: ThemeColors) -> Color {
    switch key {
    case "accent": return theme.accent
    case "orange": return theme.orange
    case "green":  return theme.green
    case "red":    return theme.red
    case "purple": return theme.purple
    default:       return theme.t3
    }
}
