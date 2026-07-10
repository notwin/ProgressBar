import SwiftUI

struct AgentAdoptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    @ObservedObject var agents: AgentIntegrationController
    let item: AgentItemSnapshot
    let sessionTitle: String

    @State private var editedTitle: String
    @State private var targetSectionID: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        state: AppState,
        agents: AgentIntegrationController,
        item: AgentItemSnapshot,
        sessionTitle: String
    ) {
        self.state = state
        self.agents = agents
        self.item = item
        self.sessionTitle = sessionTitle
        _editedTitle = State(initialValue: item.title)
        let initialSectionID = state.sections.contains { $0.id == state.activeSectionId }
            ? state.activeSectionId
            : (state.sections.first?.id ?? "")
        _targetSectionID = State(initialValue: initialSectionID)
    }

    private var trimmedTitle: String {
        editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("agent.adoption_title"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(state.theme.t1)

            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("agent.adoption_target"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(state.theme.t2)
                Picker("", selection: $targetSectionID) {
                    ForEach(state.sections) { section in
                        Text(section.name).tag(section.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(state.theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L("cancel")) { dismiss() }
                    .disabled(isSubmitting)
                Spacer()
                if isSubmitting { ProgressView().controlSize(.small) }
                Button(L("agent.adopt")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedTitle.isEmpty || targetSectionID.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(state.theme.bg)
    }

    private func submit() {
        guard !trimmedTitle.isEmpty, !targetSectionID.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true
        Task { @MainActor in
            do {
                _ = try await agents.adopt(
                    item: item,
                    sessionTitle: sessionTitle,
                    editedTitle: trimmedTitle,
                    targetSectionID: targetSectionID,
                    taskSink: state
                )
                dismiss()
            } catch {
                errorMessage = L("agent.save_failed")
                isSubmitting = false
            }
        }
    }
}
