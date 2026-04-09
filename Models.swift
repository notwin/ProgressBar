// ═══════════════════════════════════════════════════════════════════
// 数据模型（日志、任务、分区、持久化结构）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct LogEntry: Identifiable, Codable, Equatable {
    var id: String
    var date: String
    var text: String
}

enum TaskStatus: String, Codable, Equatable, CaseIterable {
    case pending = "pending"
    case inProgress = "in_progress"
    case blocked = "blocked"
    case done = "done"
}

struct TaskItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var status: TaskStatus
    var deadline: String
    var logs: [LogEntry]
    var completedAt: String?
    var isDone: Bool { status == .done }
}

struct TaskSection: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var tasks: [TaskItem]
    var archived: [TaskItem]
}

struct AppData: Codable {
    var version: Int
    var sections: [TaskSection]
    var themeId: String
    var activeSectionId: String

    init(version: Int = 1, sections: [TaskSection], themeId: String, activeSectionId: String) {
        self.version = version
        self.sections = sections
        self.themeId = themeId
        self.activeSectionId = activeSectionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sections = try container.decode([TaskSection].self, forKey: .sections)
        themeId = try container.decode(String.self, forKey: .themeId)
        activeSectionId = try container.decode(String.self, forKey: .activeSectionId)
    }
}

// ═══════════════════════════════════════════════════════════════════
// 主题颜色键枚举（类型安全替代字符串）
// ═══════════════════════════════════════════════════════════════════

enum ThemeColorKey: String {
    case accent, orange, green, red, purple, t3
}

// ═══════════════════════════════════════════════════════════════════
// 任务状态信息（图标、标签、颜色）
// ═══════════════════════════════════════════════════════════════════

struct StatusInfo {
    let icon: String
    let label: String
    let colorKey: ThemeColorKey
}

extension TaskStatus {
    /// 状态对应的图标、标签和颜色
    var info: StatusInfo {
        switch self {
        case .pending:    return StatusInfo(icon: "circle",                      label: "待开始", colorKey: .t3)
        case .inProgress: return StatusInfo(icon: "circle.fill",                 label: "进行中", colorKey: .accent)
        case .blocked:    return StatusInfo(icon: "pause.circle.fill",           label: "已阻塞", colorKey: .orange)
        case .done:       return StatusInfo(icon: "checkmark.circle.fill",       label: "已完成", colorKey: .green)
        }
    }
}

extension ThemeColors {
    /// 根据颜色键返回对应颜色
    func color(for key: ThemeColorKey) -> Color {
        switch key {
        case .accent: return accent
        case .orange: return orange
        case .green:  return green
        case .red:    return red
        case .purple: return purple
        case .t3:     return t3
        }
    }
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

/// 将 "MM.DD" 或 "YYYY.MM.DD" 格式的截止日期字符串转为 Date
func deadlineToDate(_ dl: String) -> Date? {
    let parts = dl.split(separator: ".").compactMap { Int($0) }
    let cal = Calendar.current
    if parts.count == 3 {
        // YYYY.MM.DD 格式
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    guard parts.count == 2 else { return nil }
    // MM.DD 格式（旧格式兼容，智能推断年份）
    let now = Date()
    let year = cal.component(.year, from: now)
    guard let date = cal.date(from: DateComponents(year: year, month: parts[0], day: parts[1])) else { return nil }
    if let diff = cal.dateComponents([.month], from: date, to: now).month, diff > 6 {
        return cal.date(from: DateComponents(year: year + 1, month: parts[0], day: parts[1])) ?? date
    }
    return date
}

/// 将 Date 转为 "YYYY.MM.DD" 格式字符串
func dateToDeadline(_ date: Date) -> String {
    let c = Calendar.current
    return String(format: "%04d.%02d.%02d", c.component(.year, from: date),
                  c.component(.month, from: date), c.component(.day, from: date))
}

/// 将 "MM.DD" 旧格式截止日期迁移为 "YYYY.MM.DD"
func migrateDeadlineFormat(_ dl: String) -> String {
    guard !dl.isEmpty, dl.split(separator: ".").count == 2, let date = deadlineToDate(dl) else { return dl }
    return dateToDeadline(date)
}

/// 截止日期的显示格式（只显示 MM.DD）
func deadlineDisplay(_ dl: String) -> String {
    let parts = dl.split(separator: ".")
    if parts.count == 3 { return "\(parts[1]).\(parts[2])" }
    return dl
}

/// 判断截止日期是否已过期
func isDeadlineOverdue(_ dl: String, status: TaskStatus) -> Bool {
    guard !dl.isEmpty, status != .done, let date = deadlineToDate(dl) else { return false }
    return date < Calendar.current.startOfDay(for: Date())
}
