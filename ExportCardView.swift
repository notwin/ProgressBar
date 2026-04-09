// ═══════════════════════════════════════════════════════════════════
// 导出卡片视图（用于 PNG 图片导出渲染）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ExportCardView: View {
    let section: TaskSection
    let theme: ThemeColors
    var style: ExportStyle = .desktop

    enum ExportStyle {
        case desktop, mobile

        var width: CGFloat { self == .desktop ? 560 : 390 }
        var hPad: CGFloat { self == .desktop ? 28 : 20 }
        var titleSize: CGFloat { self == .desktop ? 20 : 22 }
        var taskFontSize: CGFloat { self == .desktop ? 13 : 15 }
        var logFontSize: CGFloat { self == .desktop ? 11 : 13 }
        var dateFontSize: CGFloat { self == .desktop ? 9 : 11 }
        var iconSize: CGFloat { self == .desktop ? 14 : 17 }
        var deadlineSize: CGFloat { self == .desktop ? 10 : 12 }
        var taskVPad: CGFloat { self == .desktop ? 8 : 12 }
        var logLeading: CGFloat { self == .desktop ? 56 : 48 }
    }

    var s: ExportStyle { style }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 卡片头部
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROGRESS").font(.system(size: s == .desktop ? 10 : 11, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.t3).tracking(2)
                    Text(section.name).font(.system(size: s.titleSize, weight: .bold)).foregroundColor(theme.t1)
                }
                Spacer()
                Text(L("export.task_count_%d", section.tasks.count)).font(.system(size: s == .desktop ? 11 : 13)).foregroundColor(theme.t3)
            }.padding(.horizontal, s.hPad).padding(.top, s == .desktop ? 24 : 28).padding(.bottom, 16)

            Rectangle().fill(theme.border).frame(height: 0.5).padding(.horizontal, s.hPad)

            // 任务列表（含跟进记录）
            VStack(spacing: 0) {
                ForEach(Array(section.tasks.enumerated()), id: \.element.id) { i, task in
                    VStack(alignment: .leading, spacing: 0) {
                        // 任务主行
                        HStack(spacing: 10) {
                            let info = task.status.info
                            Image(systemName: info.icon).font(.system(size: s.iconSize))
                                .foregroundColor(theme.color(for: info.colorKey)).frame(width: 20)
                            Text(task.title).font(.system(size: s.taskFontSize, weight: .medium))
                                .foregroundColor(theme.t1).lineLimit(2)
                            Spacer()
                            if !task.deadline.isEmpty {
                                Text(deadlineDisplay(task.deadline)).font(.system(size: s.deadlineSize, design: .monospaced)).foregroundColor(theme.orange)
                            }
                        }.padding(.horizontal, s.hPad).padding(.vertical, s.taskVPad)
                        // 跟进记录
                        if !task.logs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(task.logs) { log in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(log.date)
                                            .font(.system(size: s.dateFontSize, weight: .medium, design: .monospaced))
                                            .foregroundColor(theme.accent.opacity(0.7))
                                            .frame(minWidth: s == .desktop ? 46 : 52, alignment: .leading)
                                        Text(log.text).font(.system(size: s.logFontSize)).foregroundColor(theme.t2)
                                    }
                                }
                            }.padding(.leading, s.logLeading).padding(.trailing, s.hPad).padding(.bottom, 10)
                        }
                    }
                    if i < section.tasks.count - 1 {
                        Rectangle().fill(theme.border.opacity(0.2)).frame(height: 0.5)
                            .padding(.leading, s.logLeading).padding(.trailing, s.hPad)
                    }
                }
            }.padding(.vertical, 6)

            Spacer(minLength: s == .desktop ? 16 : 20)
        }
        .background(theme.bg)
        .frame(width: s.width)
    }
}
