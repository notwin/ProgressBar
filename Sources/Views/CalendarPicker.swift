// ═══════════════════════════════════════════════════════════════════
// 自定义日历选择器（大点击区域、hover 效果、主题适配）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct CalendarPicker: View {
    @Binding var selectedDate: Date
    let theme: ThemeColors
    var onSelect: (Date) -> Void
    var onClear: (() -> Void)?

    @State private var displayMonth = Date()
    @State private var hoveredDay: Int?

    private let calendar = Calendar.current
    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private let cellSize: CGFloat = 36

    var body: some View {
        VStack(spacing: 8) {
            // 月份导航
            HStack {
                Button(action: { shiftMonth(-1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.t2)
                        .frame(width: 28, height: 28)
                        .background(theme.elevated)
                        .cornerRadius(6)
                }.buttonStyle(.plain)

                Spacer()
                Text(monthYearString)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.t1)
                Spacer()

                Button(action: { shiftMonth(1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.t2)
                        .frame(width: 28, height: 28)
                        .background(theme.elevated)
                        .cornerRadius(6)
                }.buttonStyle(.plain)
            }

            // 星期标题
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.t3)
                        .frame(width: cellSize, height: 24)
                }
            }

            // 日期网格
            let days = daysInMonth()
            let rows = days.chunked(into: 7)
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                            if day.number == 0 {
                                Color.clear.frame(width: cellSize, height: cellSize)
                            } else {
                                dayCell(day)
                            }
                        }
                    }
                }
            }

            // 清除按钮
            if let onClear = onClear {
                Divider().opacity(0.3).padding(.top, 4)
                Button(action: onClear) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        Text(L("task.clear_deadline")).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.t3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(theme.elevated)
                    .cornerRadius(6)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: cellSize * 7 + 24)
        .onAppear { displayMonth = selectedDate }
    }

    // ── 单日格子 ──

    @ViewBuilder
    func dayCell(_ day: DayInfo) -> some View {
        let isSelected = day.isSelected
        let isHovered = hoveredDay == day.uniqueId
        let isToday = day.isToday

        Button(action: { onSelect(day.date) }) {
            Text("\(day.number)")
                .font(.system(size: 13, weight: isToday ? .bold : .regular))
                .foregroundColor(
                    isSelected ? .white :
                    day.isCurrentMonth ? (isToday ? theme.accent : theme.t1) :
                    theme.t3.opacity(0.5)
                )
                .frame(width: cellSize, height: cellSize)
                .background(
                    isSelected ? theme.accent :
                    isHovered ? theme.accent.opacity(0.12) :
                    Color.clear
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredDay = h ? day.uniqueId : nil }
    }

    // ── 数据 ──

    struct DayInfo {
        let number: Int
        let date: Date
        let isCurrentMonth: Bool
        let isToday: Bool
        let isSelected: Bool
        var uniqueId: Int { isCurrentMonth ? number : (number + 200) }
    }

    var monthYearString: String {
        let c = calendar
        let year = c.component(.year, from: displayMonth)
        let month = c.component(.month, from: displayMonth)
        return L("calendar.month_year_%d_%d", year, month)
    }

    func shiftMonth(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if let next = calendar.date(byAdding: .month, value: delta, to: displayMonth) {
                displayMonth = next
            }
        }
    }

    func daysInMonth() -> [DayInfo] {
        let c = calendar
        let today = Date()

        guard let range = c.range(of: .day, in: .month, for: displayMonth),
              let firstOfMonth = c.date(from: c.dateComponents([.year, .month], from: displayMonth))
        else { return [] }

        let weekdayOfFirst = c.component(.weekday, from: firstOfMonth) - 1
        var days: [DayInfo] = []

        // 上月填充
        if weekdayOfFirst > 0, let prevMonth = c.date(byAdding: .month, value: -1, to: firstOfMonth),
           let prevRange = c.range(of: .day, in: .month, for: prevMonth) {
            let prevDays = Array(prevRange)
            for i in (prevDays.count - weekdayOfFirst)..<prevDays.count {
                guard let d = c.date(from: DateComponents(year: c.component(.year, from: prevMonth),
                    month: c.component(.month, from: prevMonth), day: prevDays[i])) else { continue }
                days.append(DayInfo(number: prevDays[i], date: d, isCurrentMonth: false,
                    isToday: c.isDate(d, inSameDayAs: today), isSelected: c.isDate(d, inSameDayAs: selectedDate)))
            }
        }

        // 当月
        for day in range {
            guard let d = c.date(from: DateComponents(year: c.component(.year, from: displayMonth),
                month: c.component(.month, from: displayMonth), day: day)) else { continue }
            days.append(DayInfo(number: day, date: d, isCurrentMonth: true,
                isToday: c.isDate(d, inSameDayAs: today), isSelected: c.isDate(d, inSameDayAs: selectedDate)))
        }

        // 下月填充至满行
        let remainder = days.count % 7
        if remainder > 0 {
            let fill = 7 - remainder
            if let nextMonth = c.date(byAdding: .month, value: 1, to: firstOfMonth) {
                for day in 1...fill {
                    guard let d = c.date(from: DateComponents(year: c.component(.year, from: nextMonth),
                        month: c.component(.month, from: nextMonth), day: day)) else { continue }
                    days.append(DayInfo(number: day, date: d, isCurrentMonth: false,
                        isToday: c.isDate(d, inSameDayAs: today), isSelected: c.isDate(d, inSameDayAs: selectedDate)))
                }
            }
        }

        return days
    }
}

// ── Array 分块扩展 ──

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
