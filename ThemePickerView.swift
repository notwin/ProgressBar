// ═══════════════════════════════════════════════════════════════════
// 主题选择器视图
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ThemePickerView: View {
    @EnvironmentObject var state: AppState
    var theme: ThemeColors { state.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外观").font(.system(size: 12, weight: .semibold)).foregroundColor(theme.t3)
                .textCase(.uppercase).tracking(0.5)

            // "自动" 选项（跟随系统外观）
            Button(action: {
                withAnimation(.spring(response: 0.3)) { state.themeId = "auto" }
                state.save()
            }) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(
                            colors: [Color(hex: "0C0E14"), Color(hex: "F8F7F4")],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(state.themeId == "auto" ? theme.accent : theme.border,
                                    lineWidth: state.themeId == "auto" ? 2 : 0.5))
                    Text("自动").font(.system(size: 14, weight: .medium)).foregroundColor(theme.t1)
                    Spacer()
                    if state.themeId == "auto" {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(theme.accent)
                    }
                }
                .padding(6)
                .background(state.themeId == "auto" ? theme.accent.opacity(0.08) : Color.clear)
                .cornerRadius(6)
            }.buttonStyle(.plain)

            Divider().opacity(0.3)

            ForEach(THEMES) { t in
                Button(action: {
                    withAnimation(.spring(response: 0.3)) { state.themeId = t.id }
                    state.save()
                }) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6).fill(t.bg).frame(width: 28, height: 28)
                            .overlay(VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 1).fill(t.accent).frame(width: 14, height: 2.5)
                                RoundedRectangle(cornerRadius: 1).fill(t.green).frame(width: 10, height: 2.5)
                                RoundedRectangle(cornerRadius: 1).fill(t.orange).frame(width: 6, height: 2.5)
                            })
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(state.themeId == t.id ? theme.accent : theme.border,
                                        lineWidth: state.themeId == t.id ? 2 : 0.5))
                        Text(t.name).font(.system(size: 14, weight: .medium)).foregroundColor(theme.t1)
                        Spacer()
                        if state.themeId == t.id {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(theme.accent)
                        }
                    }
                    .padding(6)
                    .background(state.themeId == t.id ? theme.accent.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                }.buttonStyle(.plain)
            }
        }.padding(14).frame(width: 200)
    }
}
