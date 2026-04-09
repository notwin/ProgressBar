// ═══════════════════════════════════════════════════════════════════
// GitHub Releases 检查更新 + 自动更新
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import AppKit

/// 通过 GitHub Releases API 检查新版本并支持自动更新
@MainActor
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var assetURL: String?
    @Published var releaseNotes: String?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var hasUpdate = false
    @Published var lastCheckDate: Date?
    @Published var checkError: String?
    @Published var updateError: String?

    private let repo = "notwin/ProgressBar"
    private var downloadTask: URLSessionDownloadTask?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    /// 应用安装路径
    private var appPath: String {
        Bundle.main.bundlePath
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

                // 查找 .zip 资源下载地址
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String, name.hasSuffix(".zip"),
                           let browserURL = asset["browser_download_url"] as? String {
                            self.assetURL = browserURL
                            break
                        }
                    }
                }

                self.hasUpdate = self.isNewer(remote: remote, local: self.currentVersion)
            }
        }.resume()
    }

    /// 自动更新：下载 → 解压 → 替换 → 重启
    func performUpdate() {
        guard let urlString = assetURL, let url = URL(string: urlString) else {
            updateError = "未找到下载资源"
            return
        }
        guard !isDownloading else { return }
        isDownloading = true
        updateError = nil
        downloadProgress = 0

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in self?.downloadProgress = progress }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isDownloading = false

                if let error {
                    self.updateError = "下载失败: \(error.localizedDescription)"
                    return
                }
                guard let tempURL else {
                    self.updateError = "下载失败: 未获得临时文件"
                    return
                }
                self.installUpdate(from: tempURL)
            }
        }
        downloadTask = task
        task.resume()
    }

    /// 在默认浏览器中打开下载页面
    func openDownloadPage() {
        let urlString = downloadURL ?? "https://github.com/\(repo)/releases/latest"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 安装更新：解压 → 替换 → 重启
    private func installUpdate(from zipURL: URL) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ProgressBarUpdate-\(UUID().uuidString)")

        do {
            // 创建临时解压目录
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // 解压 zip
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-o", zipURL.path, "-d", tempDir.path]
            unzipProcess.standardOutput = FileHandle.nullDevice
            unzipProcess.standardError = FileHandle.nullDevice
            try unzipProcess.run()
            unzipProcess.waitUntilExit()

            guard unzipProcess.terminationStatus == 0 else {
                updateError = "解压失败"
                try? fm.removeItem(at: tempDir)
                return
            }

            // 找到解压后的 .app
            let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                updateError = "解压后未找到应用"
                try? fm.removeItem(at: tempDir)
                return
            }

            // 用 shell 脚本完成替换和重启（因为当前进程需要先退出）
            let appDest = appPath
            let script = """
            #!/bin/bash
            sleep 1
            rm -rf "\(appDest)"
            cp -R "\(newApp.path)" "\(appDest)"
            codesign --force --sign - "\(appDest)"
            open -a "\(appDest)"
            rm -rf "\(tempDir.path)"
            """

            let scriptURL = tempDir.appendingPathComponent("update.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            // 退出当前应用
            NSApp.terminate(nil)

        } catch {
            updateError = "安装失败: \(error.localizedDescription)"
            try? fm.removeItem(at: tempDir)
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

/// 下载进度代理
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 由 completionHandler 处理
    }
}
