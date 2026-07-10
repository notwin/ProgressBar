import SwiftUI

private struct AgentAdoptionSelection: Identifiable {
    let item: AgentItemSnapshot
    let sessionTitle: String
    var id: AgentItemKey { item.key }
}

struct AgentSectionView: View {
    @ObservedObject var state: AppState
    @ObservedObject var agents: AgentIntegrationController
    let onLocate: (String) -> Void

    @State private var expandedProjects: Set<String> = []
    @State private var expandedSessions: Set<String> = []
    @State private var expandedItems: Set<AgentItemKey> = []
    @State private var adoptionSelection: AgentAdoptionSelection?

    private var theme: ThemeColors { state.theme }
    private var sessionCount: Int {
        agents.dashboard.projects.reduce(0) { $0 + $1.sessions.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border.opacity(0.15)).frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(agents.dashboard.sourceStates.filter { $0.error != nil }, id: \.source) {
                        sourceErrorBanner($0)
                    }

                    if agents.dashboard.projects.isEmpty {
                        emptyState
                    } else {
                        ForEach(agents.dashboard.projects) { project in
                            projectGroup(project)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .sheet(item: $adoptionSelection) { selection in
            AgentAdoptionSheet(
                state: state,
                agents: agents,
                item: selection.item,
                sessionTitle: selection.sessionTitle
            )
        }
        .task {
            agents.start()
            agents.setVisible(true)
        }
        .onDisappear { agents.setVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("agent.title"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.t1)
            Text(L(
                "agent.summary_%d_%d_%d",
                agents.dashboard.projects.count,
                sessionCount,
                agents.activeItemCount
            ))
            .font(.system(size: 12))
            .foregroundColor(theme.t3)

            Spacer()

            Toggle(L("agent.history"), isOn: Binding(
                get: { agents.showingHistory },
                set: { showingHistory in
                    Task { await agents.setShowingHistory(showingHistory) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .foregroundColor(theme.t2)

            Button {
                Task { await agents.refresh() }
            } label: {
                if agents.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.t3)
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .disabled(agents.isRefreshing)
            .help(L("agent.refresh"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private func sourceErrorBanner(_ sourceState: AgentSourceState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName(sourceState.source))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.t1)
                Text(L("agent.source_unavailable_%@", sourceName(sourceState.source)))
                    .font(.system(size: 11))
                    .foregroundColor(theme.t2)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = sourceState.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(theme.t3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(theme.orange.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.orange.opacity(0.25), lineWidth: 0.5))
        .cornerRadius(8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: agents.showingHistory ? "clock.arrow.circlepath" : "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(theme.t3)
            Text(emptyStateTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.t2)
            Text(emptyStateDetail)
                .font(.system(size: 12))
                .foregroundColor(theme.t3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private var emptyStateTitle: String {
        agents.showingHistory ? L("agent.empty_history") : L("agent.empty")
    }

    private var emptyStateDetail: String {
        agents.showingHistory ? "" : L("agent.no_structured_items")
    }

    private func projectGroup(_ project: AgentProjectSnapshot) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(project.id, in: $expandedProjects)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(project.sessions) { session in
                    sessionGroup(session)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.t1)
                Text(project.cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.t3)
                    .lineLimit(1)
            }
        }
        .tint(theme.t2)
        .padding(12)
        .background(theme.surface.opacity(0.65))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.opacity(0.5), lineWidth: 0.5))
        .cornerRadius(10)
    }

    private func sessionGroup(_ session: AgentSessionSnapshot) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(session.id, in: $expandedSessions)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.items) { item in
                    itemRow(item, session: session)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                sourceBadge(session.source)
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.t1)
                    .lineLimit(1)
                Spacer()
                Text(L("agent.last_updated_%@", relativeTime(session.updatedAt)))
                    .font(.system(size: 10))
                    .foregroundColor(theme.t3)
            }
        }
        .tint(theme.t2)
        .padding(10)
        .background(theme.elevated.opacity(0.7))
        .cornerRadius(8)
    }

    private func itemRow(_ item: AgentItemSnapshot, session: AgentSessionSnapshot) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(item.key, in: $expandedItems)
        ) {
            itemDetail(item)
                .padding(.leading, 24)
                .padding(.top, 5)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(item.status))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor(item.status))
                    .frame(width: 14)
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundColor(theme.t1)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let updatedAt = item.sourceUpdatedAt {
                    Text(relativeTime(updatedAt))
                        .font(.system(size: 10))
                        .foregroundColor(theme.t3)
                }
                adoptionControl(item, session: session)
            }
        }
        .tint(theme.t3)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(theme.bg.opacity(0.55))
        .cornerRadius(7)
    }

    @ViewBuilder
    private func itemDetail(_ item: AgentItemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.blockedBy.isEmpty {
                dependencyRow("arrow.down.circle", values: item.blockedBy)
            }
            if !item.blocks.isEmpty {
                dependencyRow("arrow.up.circle", values: item.blocks)
            }
            if item.description.isEmpty && item.blocks.isEmpty && item.blockedBy.isEmpty {
                Text(L("agent.no_structured_items"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.t3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dependencyRow(_ systemImage: String, values: [String]) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: systemImage)
                .foregroundColor(theme.t3)
            Text(values.joined(separator: ", "))
                .foregroundColor(theme.t2)
                .textSelection(.enabled)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    @ViewBuilder
    private func adoptionControl(
        _ item: AgentItemSnapshot,
        session: AgentSessionSnapshot
    ) -> some View {
        switch agents.adoptionPresentation(for: item.key, taskSink: state) {
        case .available:
            adoptionButton(L("agent.adopt")) {
                adoptionSelection = AgentAdoptionSelection(item: item, sessionTitle: session.title)
            }
        case .retry:
            adoptionButton(L("agent.re_adopt")) {
                adoptionSelection = AgentAdoptionSelection(item: item, sessionTitle: session.title)
            }
        case let .adopted(taskID):
            HStack(spacing: 5) {
                Text(L("agent.adopted"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.green)
                Button(action: { onLocate(taskID) }) {
                    Image(systemName: "scope")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(L("agent.adopted"))
            }
        case .adoptedTaskMissing:
            HStack(spacing: 5) {
                Text(L("agent.adopted_task_deleted"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.orange)
                adoptionButton(L("agent.re_adopt")) {
                    adoptionSelection = AgentAdoptionSelection(item: item, sessionTitle: session.title)
                }
            }
        }
    }

    private func adoptionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.bordered)
            .controlSize(.mini)
    }

    private func sourceBadge(_ source: AgentSource) -> some View {
        Text(source == .claude ? "Claude Code" : "Codex")
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .foregroundColor(source == .claude ? theme.orange : theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((source == .claude ? theme.orange : theme.accent).opacity(0.12))
            .cornerRadius(4)
    }

    private func sourceName(_ source: AgentSource) -> String {
        source == .claude ? "Claude Code" : "Codex"
    }

    private func statusIcon(_ status: AgentItemStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "play.circle.fill"
        case .blocked: return "pause.circle.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    private func statusColor(_ status: AgentItemStatus) -> Color {
        switch status {
        case .pending: return theme.t3
        case .inProgress: return theme.accent
        case .blocked: return theme.orange
        case .done: return theme.green
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func expansionBinding<ID: Hashable>(
        _ id: ID,
        in values: Binding<Set<ID>>
    ) -> Binding<Bool> {
        Binding(
            get: { values.wrappedValue.contains(id) },
            set: { expanded in
                if expanded {
                    values.wrappedValue.insert(id)
                } else {
                    values.wrappedValue.remove(id)
                }
            }
        )
    }
}
