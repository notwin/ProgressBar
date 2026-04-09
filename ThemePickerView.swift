// ═══════════════════════════════════════════════════════════════════
// 主题选择器视图
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

/// 紧凑网格主题选择器（用于设置窗口和 popover）
struct ThemePickerView: View {
    @EnvironmentObject var state: AppState
    var theme: ThemeColors { state.theme }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("theme.appearance"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase).tracking(0.5)

            LazyVGrid(columns: columns, spacing: 12) {
                // 自动选项
                themeCell(id: "auto", name: L("theme.auto"), preview: {
                    AnyView(
                        LinearGradient(
                            colors: [Color(hex: "0C0E14"), Color(hex: "F8F7F4")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                })

                // 具体主题
                ForEach(THEMES) { t in
                    themeCell(id: t.id, name: t.name, preview: {
                        AnyView(
                            ZStack {
                                t.bg
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 1).fill(t.accent).frame(width: 18, height: 3)
                                    RoundedRectangle(cornerRadius: 1).fill(t.green).frame(width: 14, height: 3)
                                    RoundedRectangle(cornerRadius: 1).fill(t.orange).frame(width: 10, height: 3)
                                }
                            }
                        )
                    })
                }
            }
        }
        .padding(14)
    }

    private func themeCell(id: String, name: String, preview: @escaping () -> AnyView) -> some View {
        let active = state.themeId == id
        return ThemeCellButton(active: active, name: name, preview: preview) {
            withAnimation(.spring(response: 0.3)) { state.themeId = id }
            state.save()
        }
    }
}

/// 单个主题格子（支持 hover 效果）
private struct ThemeCellButton: View {
    let active: Bool
    let name: String
    let preview: () -> AnyView
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.clear)
                    .frame(width: 48, height: 48)
                    .overlay(preview().clipShape(RoundedRectangle(cornerRadius: 8)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(active ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.2)),
                                    lineWidth: active ? 2.5 : (isHovered ? 1.5 : 0.5))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.accentColor)
                                .background(Circle().fill(.white).padding(1))
                                .offset(x: 4, y: 4)
                        }
                    }
                    .scaleEffect(isHovered && !active ? 1.08 : 1.0)
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(active ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(1)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}
