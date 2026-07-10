import SwiftUI

struct AgentSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var agents: AgentIntegrationController

    @State private var executablePath: String
    @State private var isApplying = false

    init(state: AppState, agents: AgentIntegrationController) {
        self.state = state
        self.agents = agents
        _executablePath = State(
            initialValue: UserDefaults.standard.string(forKey: "agent.codexExecutablePath") ?? ""
        )
    }

    private var resolvedPath: String? {
        CodexExecutableResolver().resolve()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("agent.codex_path"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(state.theme.t1)
                TextField(L("agent.codex_path_placeholder"), text: $executablePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { applyOverride() }

                HStack(spacing: 8) {
                    Button(action: applyOverride) {
                        Image(systemName: "checkmark")
                    }
                        .buttonStyle(.borderedProminent)
                        .help(L("agent.codex_path"))
                        .disabled(isApplying)
                    Button(L("agent.codex_detect")) { clearOverride() }
                        .buttonStyle(.bordered)
                        .disabled(isApplying)
                    if isApplying { ProgressView().controlSize(.small) }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: resolvedPath == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundColor(resolvedPath == nil ? state.theme.red : state.theme.green)
                    Text(resolvedPath ?? L("agent.codex_not_found"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(resolvedPath == nil ? state.theme.red : state.theme.t3)
                        .textSelection(.enabled)
                }
                .font(.system(size: 11))
            }

            Divider().overlay(state.theme.border.opacity(0.4))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    sourceHealthRow(source)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sourceHealthRow(_ source: AgentSource) -> some View {
        let sourceState = agents.dashboard.sourceStates.first { $0.source == source }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(sourceHealthColor(sourceState))
                .frame(width: 7, height: 7)
            Text(source == .claude ? "Claude Code" : "Codex")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(state.theme.t1)
            Spacer()
            if let error = sourceState?.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(state.theme.orange)
                    .lineLimit(2)
            } else if let updatedAt = sourceState?.lastSuccessAt {
                Text(L("agent.last_updated_%@", updatedAt.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 11))
                    .foregroundColor(state.theme.t3)
            }
        }
    }

    private func sourceHealthColor(_ sourceState: AgentSourceState?) -> Color {
        guard let sourceState,
              sourceState.lastScanAt != nil || sourceState.lastSuccessAt != nil
        else {
            return state.theme.t3
        }
        return sourceState.error == nil ? state.theme.green : state.theme.orange
    }

    private func applyOverride() {
        guard !isApplying else { return }
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        executablePath = trimmed
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "agent.codexExecutablePath")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "agent.codexExecutablePath")
        }
        reloadConnectors()
    }

    private func clearOverride() {
        guard !isApplying else { return }
        executablePath = ""
        UserDefaults.standard.removeObject(forKey: "agent.codexExecutablePath")
        reloadConnectors()
    }

    private func reloadConnectors() {
        isApplying = true
        Task { @MainActor in
            await agents.reloadConnectorConfiguration()
            isApplying = false
        }
    }
}
