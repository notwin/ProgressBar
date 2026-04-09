// ═══════════════════════════════════════════════════════════════════
// GitHub Releases 检查更新
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

/// 通过 GitHub Releases API 检查新版本
@MainActor
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var releaseNotes: String?
    @Published var isChecking = false
    @Published var hasUpdate = false
    @Published var lastCheckDate: Date?
    @Published var checkError: String?

    private let repo = "notwin/ProgressBar"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    /// 检查更新
    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil

        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            checkError = "无效的请求地址"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                self.lastCheckDate = Date()

                if let error {
                    self.checkError = "网络错误: \(error.localizedDescription)"
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    self.checkError = "无法解析版本信息"
                    return
                }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.latestVersion = remote
                self.releaseNotes = json["body"] as? String
                self.downloadURL = json["html_url"] as? String
                self.hasUpdate = self.isNewer(remote: remote, local: self.currentVersion)
            }
        }.resume()
    }

    /// 在默认浏览器中打开下载页面
    func openDownloadPage() {
        let urlString = downloadURL ?? "https://github.com/\(repo)/releases/latest"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 比较版本号（语义化版本）
    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
