// ═══════════════════════════════════════════════════════════════════
// 归档区视图（已完成任务的展示与管理）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ArchiveSectionView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded = false
    @State private var deleteId: String?
    @State private var showDeleteAlert = false

    var theme: ThemeColors { state.theme }
    var archived: [TaskItem] { state.activeSection?.archived ?? [] }

    var body: some View {
        if !archived.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(L("archive.title")).font(.system(size: 13, weight: .medium))
                        Text("\(archived.count)")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(theme.t3.opacity(0.15)).cornerRadius(4)
                        Spacer()
                    }.foregroundColor(theme.t3)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }.buttonStyle(.plain)

                if expanded {
                    ForEach(archived) { task in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18)).foregroundColor(theme.green.opacity(0.5))
                            Text(task.title)
                                .font(.system(size: 14)).foregroundColor(theme.t3)
                                .strikethrough(true, color: theme.t3.opacity(0.5)).lineLimit(1)
                            Spacer()
                            if let d = task.completedAt {
                                Text(d).font(.system(size: 12, design: .monospaced)).foregroundColor(theme.t3.opacity(0.6))
                            }
                            Button(action: { state.restoreTask(task.id) }) {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .medium)).foregroundColor(theme.t3)
                            }.buttonStyle(.plain).help(L("archive.restore"))
                            Button(action: { deleteId = task.id; showDeleteAlert = true }) {
                                Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundColor(theme.red.opacity(0.6))
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                    }.transition(.opacity)
                }
            }
            .alert(L("archive.delete_title"), isPresented: $showDeleteAlert) {
                Button(L("cancel"), role: .cancel) {}
                Button(L("delete"), role: .destructive) { if let id = deleteId { state.deleteArchivedTask(id) } }.keyboardShortcut(.defaultAction)
            } message: { Text(L("archive.delete_msg")) }
        }
    }
}
