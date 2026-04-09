// ═══════════════════════════════════════════════════════════════════
// 设置视图（外观 + 更新 + 关于）
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

enum SettingsTab: Hashable {
    case appearance, language, update, about
}

struct LanguageOption: Identifiable {
    let id: String
    let name: String
}

private let languages: [LanguageOption] = [
    LanguageOption(id: "auto", name: "Auto"),
    LanguageOption(id: "en", name: "English (United States)"),
    LanguageOption(id: "fr", name: "Français (France)"),
    LanguageOption(id: "de", name: "Deutsch (Deutschland)"),
    LanguageOption(id: "hi", name: "हिन्दी (भारत)"),
    LanguageOption(id: "id", name: "Indonesia (Indonesia)"),
    LanguageOption(id: "it", name: "Italiano (Italia)"),
    LanguageOption(id: "ja", name: "日本語 (日本)"),
    LanguageOption(id: "ko", name: "한국어(대한민국)"),
    LanguageOption(id: "pt-BR", name: "Português (Brasil)"),
    LanguageOption(id: "es-419", name: "Español (Latinoamérica)"),
    LanguageOption(id: "es", name: "Español (España)"),
    LanguageOption(id: "zh-Hans", name: "简体中文"),
    LanguageOption(id: "zh-Hant", name: "繁體中文"),
]

private struct LanguageRow: View {
    let lang: LanguageOption
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(lang.name).font(.system(size: 14, weight: isActive ? .semibold : .medium))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.08) :
                          (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

struct LanguagePickerView: View {
    @State private var currentLang: String = {
        if let langs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let first = langs.first {
            let supported = ["zh-Hant", "zh-Hans", "en", "fr", "de", "hi", "id", "it", "ja", "ko", "pt-BR", "es-419", "es"]
            // exact match first
            if supported.contains(first) { return first }
            // prefix match
            for s in supported {
                if first.hasPrefix(s) || s.hasPrefix(first) { return s }
            }
        }
        return "auto"
    }()
    @State private var showRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.language"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase).tracking(0.5)

            ForEach(languages) { lang in
                LanguageRow(lang: lang, isActive: lang.id == currentLang) {
                    if lang.id == currentLang { return }
                    currentLang = lang.id
                    if lang.id == "auto" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([lang.id], forKey: "AppleLanguages")
                    }
                    showRestart = true
                }
            }

            if showRestart {
                HStack(spacing: 8) {
                    Text(L("settings.restart_hint"))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Spacer()
                    Button(L("settings.restart")) {
                        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
                        NSWorkspace.shared.open(url)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApp.terminate(nil)
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var updater: UpdateChecker
    @State var selectedTab: SettingsTab = .appearance

    var theme: ThemeColors { state.theme }

    var body: some View {
        TabView(selection: $selectedTab) {
            appearanceTab.tabItem { Label(L("settings.appearance"), systemImage: "paintbrush") }.tag(SettingsTab.appearance)
            languageTab.tabItem { Label(L("settings.language"), systemImage: "globe") }.tag(SettingsTab.language)
            updateTab.tabItem { Label(L("settings.update"), systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.update)
            aboutTab.tabItem { Label(L("settings.about"), systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── 外观 ──
    private var appearanceTab: some View {
        ScrollView {
            ThemePickerView().environmentObject(state)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── 语言 ──
    private var languageTab: some View {
        ScrollView {
            LanguagePickerView()
                .frame(maxWidth: .infinity)
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
                Text(L("update.found_%@", updater.latestVersion ?? ""))
                    .font(.system(size: 16, weight: .semibold))
                Text(L("update.current_%@", updater.currentVersion))
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

                if updater.isDownloading {
                    VStack(spacing: 6) {
                        ProgressView(value: updater.downloadProgress)
                            .frame(width: 200)
                        Text(L("update.downloading_%d", Int(updater.downloadProgress * 100)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 12) {
                        Button(L("update.auto")) { updater.performUpdate() }
                            .buttonStyle(.borderedProminent)
                        Button(L("update.download")) { updater.openDownloadPage() }
                    }
                }
                if let err = updater.updateError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            } else if updater.isChecking {
                ProgressView()
                    .scaleEffect(0.8)
                Text(L("update.checking"))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else if let error = updater.checkError {
                Text(L("update.failed"))
                    .font(.system(size: 16, weight: .semibold))
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button(L("update.retry")) { updater.checkForUpdates() }
            } else {
                Text(L("update.latest"))
                    .font(.system(size: 16, weight: .semibold))
                Text("v\(updater.currentVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack {
                if let date = updater.lastCheckDate {
                    Text(L("update.last_check_%@", date.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(L("update.check")) { updater.checkForUpdates() }
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

            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            Text(L("about.name"))
                .font(.system(size: 20, weight: .bold))

            Text("v\(updater.currentVersion)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text(L("about.description"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 16) {
                Button(L("about.github")) {
                    if let url = URL(string: "https://github.com/notwin/ProgressBar") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(L("about.feedback")) {
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
