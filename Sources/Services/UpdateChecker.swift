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
    @Published var assetName: String?
    @Published var releaseNotes: String?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var hasUpdate = false
    @Published var lastCheckDate: Date?
    @Published var checkError: String?
    @Published var updateError: String?

    private let repo = "notwin/ProgressBar"
    private let lastCheckKey = "lastUpdateCheckDate"
    private var downloadTask: URLSessionDownloadTask?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    /// 启动时静默检查（每天最多一次）
    func checkOnLaunchIfNeeded() {
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           now.timeIntervalSince(last) < 86400 { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        checkForUpdates()
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
            checkError = L("error.invalid_url")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let s = self
            Task { @MainActor in
                guard let s else { return }
                s.isChecking = false
                s.lastCheckDate = Date()

                if let error {
                    s.checkError = L("error.network_%@", error.localizedDescription)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    s.checkError = L("error.parse_version")
                    return
                }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                s.latestVersion = remote
                s.releaseNotes = json["body"] as? String
                s.downloadURL = json["html_url"] as? String

                // 查找 .zip 资源下载地址
                if let assets = json["assets"] as? [[String: Any]] {
                    for asset in assets {
                        if let name = asset["name"] as? String, (name.hasSuffix(".dmg") || name.hasSuffix(".zip")),
                           let browserURL = asset["browser_download_url"] as? String {
                            s.assetURL = browserURL
                            s.assetName = name
                            break
                        }
                    }
                }

                s.hasUpdate = s.isNewer(remote: remote, local: s.currentVersion)
            }
        }.resume()
    }

    /// 取消正在进行的下载
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    /// 自动更新：下载 → 解压 → 替换 → 重启
    func performUpdate() {
        guard let urlString = assetURL, let url = URL(string: urlString) else {
            updateError = L("error.no_asset")
            return
        }
        guard !isDownloading else { return }
        cancelDownload()
        isDownloading = true
        updateError = nil
        downloadProgress = 0

        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor in self?.downloadProgress = progress }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            let s = self
            Task { @MainActor in
                guard let s else { return }
                s.isDownloading = false

                if let error {
                    s.updateError = L("error.download_%@", error.localizedDescription)
                    return
                }
                guard let tempURL else {
                    s.updateError = L("error.download_no_file")
                    return
                }
                let isDMG = s.assetName?.hasSuffix(".dmg") ?? false
                s.installUpdate(from: tempURL, isDMG: isDMG)
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

    /// 安装更新：解压/挂载 → 替换 → 重启
    private func installUpdate(from fileURL: URL, isDMG: Bool) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ProgressBarUpdate-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            var appSourceDir = tempDir
            var mountPoint: String?

            if isDMG {
                // 临时文件需要 .dmg 扩展名才能挂载
                let dmgFile = tempDir.appendingPathComponent("update.dmg")
                try fm.copyItem(at: fileURL, to: dmgFile)

                // 挂载 DMG
                let mp = "/Volumes/Progress-\(UUID().uuidString.prefix(8))"
                let attach = Process()
                attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                attach.arguments = ["attach", dmgFile.path, "-mountpoint", mp, "-nobrowse", "-quiet"]
                try attach.run()
                attach.waitUntilExit()
                guard attach.terminationStatus == 0 else {
                    updateError = L("error.unzip")
                    try? fm.removeItem(at: tempDir)
                    return
                }
                mountPoint = mp
                appSourceDir = URL(fileURLWithPath: mp)
            } else {
                // 解压 zip
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", fileURL.path, "-d", tempDir.path]
                unzip.standardOutput = FileHandle.nullDevice
                unzip.standardError = FileHandle.nullDevice
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    updateError = L("error.unzip")
                    try? fm.removeItem(at: tempDir)
                    return
                }
            }

            // 找到 .app
            let contents = try fm.contentsOfDirectory(at: appSourceDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                updateError = L("error.no_app")
                if let mp = mountPoint { detachDMG(mp) }
                try? fm.removeItem(at: tempDir)
                return
            }

            // 复制 app 到临时目录（DMG 是只读的）
            let stagingApp: URL
            if isDMG {
                stagingApp = tempDir.appendingPathComponent(newApp.lastPathComponent)
                try fm.copyItem(at: newApp, to: stagingApp)
                detachDMG(mountPoint!)
            } else {
                stagingApp = newApp
            }

            // shell 脚本完成替换和重启
            let appDest = appPath
            let script = """
            #!/bin/bash
            sleep 1
            rm -rf "\(appDest)"
            cp -R "\(stagingApp.path)" "\(appDest)"
            codesign --force --sign - "\(appDest)"
            # 清除窗口状态缓存，防止恢复旧尺寸
            rm -rf ~/Library/Saved\\ Application\\ State/com.notwin.progressbar.savedState
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

            NSApp.terminate(nil)

        } catch {
            updateError = L("error.install_%@", error.localizedDescription)
            try? fm.removeItem(at: tempDir)
        }
    }

    /// 卸载 DMG
    private func detachDMG(_ mountPoint: String) {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint, "-quiet"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        try? detach.run()
        detach.waitUntilExit()
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
