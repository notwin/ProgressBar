// ═══════════════════════════════════════════════════════════════════
// 设置视图（外观 + 更新 + 关于）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

enum SettingsTab: Hashable {
    case appearance, update, about
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var updater: UpdateChecker
    @State var selectedTab: SettingsTab = .appearance

    var theme: ThemeColors { state.theme }

    var body: some View {
        TabView(selection: $selectedTab) {
            appearanceTab.tabItem { Label("外观", systemImage: "paintbrush") }.tag(SettingsTab.appearance)
            updateTab.tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.update)
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 420, height: 340)
    }

    // ── 外观 ──
    private var appearanceTab: some View {
        VStack(spacing: 0) {
            ThemePickerView().environmentObject(state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── 更新 ──
    private var updateTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: updater.hasUpdate ? "arrow.down.circle" : "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(updater.hasUpdate ? .orange : .green)

            if updater.hasUpdate {
                Text("发现新版本 v\(updater.latestVersion ?? "")")
                    .font(.system(size: 16, weight: .semibold))
                Text("当前版本: v\(updater.currentVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if let notes = updater.releaseNotes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 80)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal, 20)
                }

                Button("前往下载") { updater.openDownloadPage() }
                    .buttonStyle(.borderedProminent)
            } else if updater.isChecking {
                ProgressView()
                    .scaleEffect(0.8)
                Text("正在检查更新...")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else if let error = updater.checkError {
                Text("检查失败")
                    .font(.system(size: 16, weight: .semibold))
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button("重试") { updater.checkForUpdates() }
            } else {
                Text("已是最新版本")
                    .font(.system(size: 16, weight: .semibold))
                Text("v\(updater.currentVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack {
                if let date = updater.lastCheckDate {
                    Text("上次检查: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("检查更新") { updater.checkForUpdates() }
                    .disabled(updater.isChecking)
            }
        }
        .padding(20)
        .onAppear { updater.checkForUpdates() }
    }

    // ── 关于 ──
    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("进度条")
                .font(.system(size: 20, weight: .bold))

            Text("v\(updater.currentVersion)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text("一个简洁的 macOS 任务进度管理工具")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 16) {
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/notwin/ProgressBar") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("反馈问题") {
                    if let url = URL(string: "https://github.com/notwin/ProgressBar/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.bottom, 8)
        }
        .padding(20)
    }
}
