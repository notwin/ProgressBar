// ═══════════════════════════════════════════════════════════════════
// 分区标签栏视图（切换、新建、重命名、删除分区）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SectionTabBar: View {
    @EnvironmentObject var state: AppState
    @State private var showAdd = false
    @State private var newName = ""
    @State private var editId: String?
    @State private var editName = ""
    @State private var deleteId: String?
    @State private var showDeleteAlert = false

    var theme: ThemeColors { state.theme }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.sections) { sec in
                    let active = sec.id == state.activeSectionId
                    if editId == sec.id {
                        TextField("", text: $editName, onCommit: {
                            if !editName.isEmpty { state.renameSection(sec.id, name: editName) }
                            editId = nil
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.t1)
                        .frame(minWidth: 80)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(theme.accent.opacity(0.15))
                        .cornerRadius(8)
                    } else {
                        Button(action: {
                            withAnimation(.appSpring) {
                                state.activeSectionId = sec.id
                            }
                            state.save()
                        }) {
                            HStack(spacing: 4) {
                                Text(sec.name)
                                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                                    .foregroundColor(active ? .white : theme.t2)
                                if !sec.tasks.isEmpty {
                                    Text("\(sec.tasks.count)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(active ? .white.opacity(0.7) : theme.t3)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(active ? theme.accent : Color.clear)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重命名") { editName = sec.name; editId = sec.id }
                            if state.sections.count > 1 {
                                Divider()
                                Button("删除分区", role: .destructive) { deleteId = sec.id; showDeleteAlert = true }
                            }
                        }
                    }
                }

                // 新建分区按钮
                Button(action: { showAdd.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.t3)
                        .frame(width: 30, height: 30)
                        .background(theme.surface)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    VStack(spacing: 10) {
                        Text("新建分区").font(.system(size: 14, weight: .semibold)).foregroundColor(theme.t1)
                        TextField("", text: $newName, prompt: Text("分区名称").foregroundColor(theme.t3))
                            .textFieldStyle(.plain).font(.system(size: 14))
                            .padding(8).background(theme.bg).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 0.5))
                            .onSubmit { doAdd() }
                        HStack {
                            Button("取消") { showAdd = false }.foregroundColor(theme.t3)
                            Spacer()
                            Button("创建") { doAdd() }.foregroundColor(theme.accent)
                        }.font(.system(size: 14, weight: .medium)).buttonStyle(.plain)
                    }.padding(14).frame(width: 200)
                }
            }
            .padding(.horizontal, 24)
        }
        .alert("确认删除分区", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { if let id = deleteId { state.deleteSection(id) } }.keyboardShortcut(.defaultAction)
        } message: {
            if let id = deleteId, let sec = state.sections.first(where: { $0.id == id }) {
                Text("确定删除「\(sec.name)」？其中 \(sec.tasks.count + sec.archived.count) 个任务将被永久删除。")
            }
        }
    }

    func doAdd() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        state.addSection(name: n); newName = ""; showAdd = false
    }
}
