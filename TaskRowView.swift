// ═══════════════════════════════════════════════════════════════════
// 任务行视图（状态切换、编辑、日志、截止日期）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct TaskRowView: View {
    @EnvironmentObject var state: AppState
    let task: TaskItem
    let index: Int

    @State private var expanded = true
    @State private var showAllLogs = false
    @State private var hovered = false
    @State private var showStatusMenu = false
    @State private var showCompleteAlert = false
    @State private var showDeleteAlert = false
    @State private var showDeleteLogAlert = false
    @State private var deleteLogId: String?
    @State private var logInput = ""
    @State private var showLogInput = false
    @FocusState private var logInputFocused: Bool
    @FocusState private var titleInputFocused: Bool
    @State private var editingTitle = false
    @State private var editedTitle = ""
    @State private var showDeadlinePicker = false
    @State private var pickedDate = Date()
    @State private var isDragging = false

    var theme: ThemeColors { state.theme }
    var info: StatusInfo { statusInfo(for: task.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 主行内容 ──
            HStack(spacing: 12) {
                // 状态图标按钮
                Button(action: { showStatusMenu.toggle() }) {
                    Image(systemName: info.icon)
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(themeColor(for: info.colorKey, theme))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showStatusMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(STATUS_OPTIONS, id: \.key) { key, opt in
                            Button(action: { state.setStatus(task.id, key); showStatusMenu = false }) {
                                HStack(spacing: 8) {
                                    Image(systemName: opt.icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(themeColor(for: opt.colorKey, theme))
                                        .frame(width: 18)
                                    Text(opt.label).font(.system(size: 13)).foregroundColor(theme.t1)
                                    Spacer()
                                    if task.status == key {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(theme.accent)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(task.status == key ? theme.accent.opacity(0.08) : Color.clear)
                                .cornerRadius(6)
                            }.buttonStyle(.plain)
                        }
                        Divider().padding(.vertical, 4)
                        Button(action: { showStatusMenu = false; showCompleteAlert = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "archivebox").font(.system(size: 14)).foregroundColor(theme.t3).frame(width: 18)
                                Text("归档").font(.system(size: 13, weight: .medium)).foregroundColor(theme.t3)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }.padding(8).frame(minWidth: 170)
                }

                // 任务标题
                if editingTitle {
                    TextField("", text: $editedTitle, prompt: Text("任务名称").foregroundColor(theme.t3))
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundColor(theme.t1)
                    .focused($titleInputFocused)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { titleInputFocused = true }
                    }
                    .onSubmit {
                        if !editedTitle.isEmpty { state.editTitle(task.id, editedTitle) }
                        editingTitle = false
                    }
                    .onExitCommand { editingTitle = false }
                } else {
                    Text(task.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.t1)
                        .lineLimit(1).truncationMode(.tail)
                        .help(task.title)
                        .onTapGesture(count: 2) { editedTitle = task.title; editingTitle = true }
                }

                Spacer()

                // 悬浮操作按钮（始终占位，hover 时显示）
                HStack(spacing: 2) {
                    hoverBtn("plus", theme.accent) { withAnimation(.easeOut(duration: 0.12)) { expanded = true; showLogInput = true } }
                    hoverBtn("archivebox", theme.t3) { showCompleteAlert = true }
                    hoverBtn("trash", theme.red) { showDeleteAlert = true }
                }.opacity(hovered ? 1 : 0)

                // 截止日期
                if !task.deadline.isEmpty {
                    HStack(spacing: 4) {
                        if state.syncedTaskTitles.contains(task.title) {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.system(size: 10))
                                .foregroundColor(theme.purple)
                        }
                        Button(action: { pickedDate = deadlineToDate(task.deadline); showDeadlinePicker = true }) {
                            let overdue = task.status != "done" && isDeadlineOverdue(task.deadline)
                            let dlColor = overdue ? theme.red : theme.orange
                            HStack(spacing: 3) {
                                if overdue {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                                }
                                Text(task.deadline)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(dlColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(dlColor.opacity(0.1)).cornerRadius(4)
                        }.buttonStyle(.plain)
                    }
                } else {
                    Button(action: { pickedDate = Date(); showDeadlinePicker = true }) {
                        Image(systemName: "calendar.badge.plus").font(.system(size: 11)).foregroundColor(theme.t3)
                    }.buttonStyle(.plain).opacity(hovered ? 1 : 0)
                }

                // 展开箭头
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium)).foregroundColor(theme.t3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.appSpring, value: expanded)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                if editingTitle {
                    if !editedTitle.isEmpty { state.editTitle(task.id, editedTitle) }
                    editingTitle = false
                } else {
                    withAnimation(.appSpring) { expanded.toggle() }
                }
            }

            // ── 展开的日志区域 ──
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if task.logs.isEmpty {
                        Text("暂无进展记录").font(.system(size: 12)).foregroundColor(theme.t3).padding(.bottom, 8)
                    }
                    let visibleLogs = showAllLogs ? task.logs : Array(task.logs.suffix(3))
                    if task.logs.count > 3 && !showAllLogs {
                        Button(action: { withAnimation(.easeOut(duration: 0.15)) { showAllLogs = true } }) {
                            Text("查看全部 \(task.logs.count) 条记录")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accent.opacity(0.7))
                        }.buttonStyle(.plain).padding(.bottom, 4)
                    }
                    ForEach(visibleLogs) { log in
                        HStack(alignment: .top, spacing: 10) {
                            Text(log.date)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.accent.opacity(0.8)).frame(minWidth: 52, alignment: .leading)
                            Text(log.text).font(.system(size: 13)).foregroundColor(theme.t2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(action: { deleteLogId = log.id; showDeleteLogAlert = true }) {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    .foregroundColor(theme.t3.opacity(0.3)).frame(width: 14, height: 14)
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 3)
                        if log.id != visibleLogs.last?.id { Divider().opacity(0.15) }
                    }
                    if task.logs.count > 3 && showAllLogs {
                        Button(action: { withAnimation(.easeOut(duration: 0.15)) { showAllLogs = false } }) {
                            Text("收起")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accent.opacity(0.7))
                        }.buttonStyle(.plain).padding(.top, 4)
                    }

                    // 添加日志：点击 + 展开输入框
                    if showLogInput {
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                if logInput.isEmpty {
                                    Text("记录进展...")
                                        .font(.system(size: 13))
                                        .foregroundColor(logInputFocused ? theme.t3.opacity(0.3) : theme.t3)
                                        .allowsHitTesting(false)
                                }
                                TextField("", text: $logInput)
                                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(theme.t1)
                                    .focused($logInputFocused)
                                    .onSubmit { submitLog() }
                                    .onAppear { logInputFocused = true }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(theme.bg).cornerRadius(5)
                            Button(action: submitLog) {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                                    .foregroundColor(logInput.trimmingCharacters(in: .whitespaces).isEmpty ? theme.t3 : theme.accent)
                            }.buttonStyle(.plain)
                            Button(action: { withAnimation(.easeOut(duration: 0.12)) { showLogInput = false; logInput = "" } }) {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .foregroundColor(theme.t3)
                            }.buttonStyle(.plain)
                        }.padding(.top, 4).transition(.opacity)
                    }
                }
                .padding(.leading, 44).padding(.trailing, 14).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(hovered ? theme.surface : Color.clear)
        .cornerRadius(10)
        .opacity(isDragging ? 0.5 : 1.0)
        .onDrag {
            isDragging = true
            return NSItemProvider(object: task.id as NSString)
        }
        .onDrop(of: [.text], delegate: TaskDropDelegate(taskId: task.id, state: state, isDragging: $isDragging))
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovered = h } }
        .alert("确认归档", isPresented: $showCompleteAlert) {
            Button("取消", role: .cancel) {}
            Button("归档") { state.completeTask(task.id) }.keyboardShortcut(.defaultAction)
        } message: { Text("确定将「\(task.title)」归档吗？") }
        .alert("确认删除", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { state.deleteTask(task.id) }.keyboardShortcut(.defaultAction)
        } message: { Text("确定删除「\(task.title)」吗？此操作不可撤销。") }
        .alert("确认删除记录", isPresented: $showDeleteLogAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { if let id = deleteLogId { state.deleteLog(task.id, logId: id) } }.keyboardShortcut(.defaultAction)
        } message: { Text("确定删除这条进展记录吗？") }
        .popover(isPresented: $showDeadlinePicker, arrowEdge: .bottom) {
            CalendarPicker(
                selectedDate: $pickedDate,
                theme: theme,
                onSelect: { date in
                    state.setDeadline(task.id, dateToDeadline(date))
                    showDeadlinePicker = false
                },
                onClear: task.deadline.isEmpty ? nil : {
                    state.setDeadline(task.id, "")
                    showDeadlinePicker = false
                }
            )
        }
    }

    func submitLog() {
        let text = logInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        state.addLog(task.id, text: text); logInput = ""
        withAnimation(.easeOut(duration: 0.15)) { showLogInput = false }
    }

    @ViewBuilder
    func hoverBtn(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundColor(color).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// ═══════════════════════════════════════════════════════════════════
// 拖拽排序代理
// ═══════════════════════════════════════════════════════════════════

struct TaskDropDelegate: DropDelegate {
    let taskId: String
    let state: AppState
    @Binding var isDragging: Bool

    func performDrop(info: DropInfo) -> Bool {
        isDragging = false
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let item = info.itemProviders(for: [.text]).first else { return }
        item.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { data, _ in
            guard let data = data as? Data, let fromId = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                if fromId != taskId {
                    state.reorderTask(fromId: fromId, toId: taskId)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isDragging = false
    }
}
