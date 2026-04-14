// ═══════════════════════════════════════════════════════════════════
// 快捷悬浮输入视图（分区切换 + 实时过滤候选 + ↑↓ 选择 + 回车提交）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

private enum QuickCandidate: Identifiable {
    case newTask
    case existing(TaskItem)

    var id: String {
        switch self {
        case .newTask: return "__new__"
        case .existing(let t): return t.id
        }
    }
}

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct QuickInputView: View {
    @EnvironmentObject var state: AppState
    let onDismiss: () -> Void
    var onSizeChange: ((CGSize) -> Void)? = nil

    @State private var input = ""
    @State private var targetSectionId: String = ""
    @State private var selectedIndex: Int = 0
    @State private var pinnedTask: TaskItem? = nil   // 非 nil 时进入"加进展"阶段
    @FocusState private var focused: Bool

    private var theme: ThemeColors { state.theme }

    // ── 悬浮窗文字层级（语义化，避免散落 t1/t2/t3） ──────────
    /// 主文字：标题、任务名、输入内容、日志正文
    private var primaryText: Color { theme.t1 }
    /// 次要文字：placeholder、日期戳、辅助 hint —— 要求在 elevated 深底下仍清晰可读
    private var secondaryText: Color { theme.t2 }
    /// 装饰 icon / disabled 状态
    private var tertiaryText: Color { theme.t3 }

    private var targetSection: TaskSection? {
        state.sections.first(where: { $0.id == targetSectionId })
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespaces) }

    /// 实时获取 pin 任务（含最新 logs，pin 后加进展能立刻反映）
    private var pinnedTaskLive: TaskItem? {
        guard let id = pinnedTask?.id else { return nil }
        return targetSection?.tasks.first(where: { $0.id == id })
    }

    private var candidates: [QuickCandidate] {
        // pin 状态下不显示候选列表
        if pinnedTask != nil { return [] }

        let tasks = targetSection?.tasks ?? []
        var result: [QuickCandidate] = []

        if !trimmedInput.isEmpty {
            result.append(.newTask)
        }

        let filtered: [TaskItem]
        if trimmedInput.isEmpty {
            filtered = Array(tasks.prefix(6))
        } else {
            filtered = tasks
                .filter { $0.title.localizedCaseInsensitiveContains(trimmedInput) }
                .prefix(6)
                .map { $0 }
        }
        result.append(contentsOf: filtered.map { .existing($0) })
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if pinnedTask != nil, let live = pinnedTaskLive, !live.logs.isEmpty {
                Rectangle().fill(theme.border.opacity(0.15)).frame(height: 0.5)
                pinnedLogsList(live)
            } else if pinnedTask == nil, !candidates.isEmpty {
                Rectangle().fill(theme.border.opacity(0.15)).frame(height: 0.5)
                candidatesList
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.border.opacity(0.15), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(6)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SizePreferenceKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self) { size in
            onSizeChange?(size)
        }
        .onAppear {
            if targetSectionId.isEmpty { targetSectionId = state.activeSectionId }
            selectedIndex = 0
        }
        .onChange(of: input) { _, _ in
            // 输入变化时重置到第一个候选
            selectedIndex = 0
        }
        .onChange(of: targetSectionId) { _, _ in
            selectedIndex = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickInputCycleSection)) { note in
            let direction = (note.userInfo?["direction"] as? Int) ?? 1
            cycleSection(direction)
        }
        .task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            focused = true
        }
    }

    // ── 输入行 ────────────────────────────────────────────────
    private var inputRow: some View {
        HStack(spacing: 10) {
            if let task = pinnedTask {
                pinnedBadge(task)
            } else {
                sectionPicker
            }

            ZStack(alignment: .leading) {
                if input.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(focused ? tertiaryText.opacity(0.5) : tertiaryText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(primaryText)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) {
                        moveSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(1)
                        return .handled
                    }
                    .onKeyPress(.delete) {
                        if pinnedTask != nil && input.isEmpty {
                            unpin()
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.escape) {
                        if pinnedTask != nil {
                            unpin()
                            return .handled
                        }
                        onDismiss()
                        return .handled
                    }
            }
            .frame(maxWidth: .infinity)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSubmit ? theme.accent : tertiaryText)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func pinnedBadge(_ task: TaskItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "list.bullet")
                .font(.system(size: 11, weight: .semibold))
            Text(task.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: unpin) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.accent.opacity(0.12))
        .cornerRadius(6)
        .fixedSize()
    }

    // ── 分区选择按钮 ───────────────────────────────────────────
    private var sectionPicker: some View {
        Menu {
            ForEach(state.sections) { section in
                Button(section.name) { targetSectionId = section.id }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text(targetSection?.name ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(primaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.bg)
            .cornerRadius(6)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // ── 进展历史（pin 状态下显示该任务现有 logs） ────────────
    @ViewBuilder
    private func pinnedLogsList(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 最新 5 条，倒序（最近的在上）
            let recent = Array(task.logs.suffix(5).reversed())
            ForEach(recent, id: \.id) { log in
                HStack(alignment: .top, spacing: 10) {
                    Text(log.date)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(secondaryText)
                        .frame(width: 62, alignment: .leading)
                    Text(log.text)
                        .font(.system(size: 12))
                        .foregroundStyle(primaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }
            if task.logs.count > 5 {
                Text(L("quick_input.logs_more_%d", task.logs.count - 5))
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }

    // ── 候选列表 ───────────────────────────────────────────────
    private var candidatesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, cand in
                candidateRow(cand, isSelected: idx == selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedIndex = idx
                        submit()
                    }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func candidateRow(_ cand: QuickCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch cand {
            case .newTask:
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.accent)
                    .frame(width: 20)
                Text(L("quick_input.new_task_%@", trimmedInput))
                    .font(.system(size: 13))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .existing(let task):
                Image(systemName: "list.bullet")
                    .font(.system(size: 12))
                    .foregroundStyle(tertiaryText)
                    .frame(width: 20)
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !trimmedInput.isEmpty {
                    Spacer()
                    Text(L("quick_input.add_log_hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? theme.accent.opacity(0.15) : Color.clear)
    }

    // ── 行为 ───────────────────────────────────────────────────
    private var placeholder: String {
        if pinnedTask != nil {
            return L("quick_input.placeholder.log")
        }
        return L("quick_input.placeholder.universal")
    }

    private var canSubmit: Bool {
        if pinnedTask != nil {
            return !trimmedInput.isEmpty
        }
        guard selectedIndex < candidates.count else { return false }
        switch candidates[selectedIndex] {
        case .newTask:
            return !trimmedInput.isEmpty
        case .existing:
            return true   // 选中已有任务时允许（进入 pin 阶段，无需此时有输入）
        }
    }

    private func submit() {
        // pin 状态：输入作为进展提交
        if let task = pinnedTask {
            let text = trimmedInput
            guard !text.isEmpty else { return }
            state.addLog(task.id, in: targetSectionId, text: text)
            input = ""
            onDismiss()
            return
        }
        // 搜索状态：根据选中项决定
        guard selectedIndex < candidates.count else { return }
        switch candidates[selectedIndex] {
        case .newTask:
            guard !trimmedInput.isEmpty else { return }
            state.addTask(title: trimmedInput, to: targetSectionId)
            input = ""
            onDismiss()
        case .existing(let task):
            // 进入 pin 阶段，清空输入让用户录进展
            pinnedTask = task
            input = ""
        }
    }

    private func unpin() {
        pinnedTask = nil
        selectedIndex = 0
    }

    private func moveSelection(_ delta: Int) {
        let count = candidates.count
        guard count > 0 else { return }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(count - 1, next))
    }

    private func cycleSection(_ direction: Int = 1) {
        guard !state.sections.isEmpty,
              let idx = state.sections.firstIndex(where: { $0.id == targetSectionId }) else { return }
        let count = state.sections.count
        let next = ((idx + direction) % count + count) % count
        targetSectionId = state.sections[next].id
    }
}
