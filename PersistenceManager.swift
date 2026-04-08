// ═══════════════════════════════════════════════════════════════════
// 持久化管理器（数据加载、保存、iCloud 同步）
// ═══════════════════════════════════════════════════════════════════

import Foundation

@MainActor
class PersistenceManager {
    // ── 文件路径 ──

    static let localDir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ProgressBar")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let iCloudDir: URL? = {
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: cloud.path) else { return nil }
        let d = cloud.appendingPathComponent("ProgressBar")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    var iCloudAvailable: Bool { Self.iCloudDir != nil }

    var dataURL: URL {
        (Self.iCloudDir ?? Self.localDir).appendingPathComponent("data.json")
    }

    private var lastFileDate: Date?
    private var saveGeneration: UInt64 = 0

    /// 错误报告回调
    var onError: ((String) -> Void)?

    // ── 数据持久化 ──

    /// 从磁盘加载数据结果
    enum LoadResult {
        case loaded(AppData)
        case migrated([TaskItem])
        case empty
        case corrupted(Data)
    }

    /// 从磁盘加载数据，支持新旧格式自动迁移
    func load() -> LoadResult {
        // 先尝试主路径（iCloud 优先）
        if let result = tryLoad(from: dataURL) {
            lastFileDate = fileModDate()
            return result
        }
        // 主路径失败时，尝试本地备份
        if Self.iCloudDir != nil {
            let localURL = Self.localDir.appendingPathComponent("data.json")
            if let result = tryLoad(from: localURL) {
                onError?("iCloud 数据异常，已从本地备份恢复")
                lastFileDate = fileModDate()
                return result
            }
        }
        return .empty
    }

    /// 尝试从指定路径加载数据
    private func tryLoad(from url: URL) -> LoadResult? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let appData = try? JSONDecoder().decode(AppData.self, from: data) {
            return .loaded(appData)
        }
        if let oldTasks = try? JSONDecoder().decode([TaskItem].self, from: data) {
            return .migrated(oldTasks)
        }
        return .corrupted(data)
    }

    /// 备份损坏的数据文件
    func backupCorruptedData(_ data: Data) {
        let backupURL = dataURL.deletingLastPathComponent()
            .appendingPathComponent("data.corrupt.\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: backupURL)
        } catch {
            onError?("备份损坏数据失败: \(error.localizedDescription)")
        }
    }

    /// 将当前数据保存到磁盘
    func save(appData: AppData) {
        saveGeneration &+= 1
        do {
            let data = try JSONEncoder().encode(appData)
            try data.write(to: dataURL, options: .atomic)
            if Self.iCloudDir != nil {
                let local = Self.localDir.appendingPathComponent("data.json")
                try? data.write(to: local, options: .atomic)
            }
        } catch {
            onError?("数据保存失败: \(error.localizedDescription)")
        }
        lastFileDate = fileModDate()
    }

    /// 获取数据文件的最后修改时间
    func fileModDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: dataURL.path)[.modificationDate] as? Date
    }

    /// 检查远程文件是否有更新，返回 true 表示需要重新加载
    func hasRemoteChanges() -> Bool {
        let gen = saveGeneration
        guard let cur = fileModDate(), let last = lastFileDate, cur > last, gen == saveGeneration else { return false }
        return true
    }

    /// 读取旧版主题 ID
    func readLegacyThemeId() -> String? {
        let oldThemeURL = Self.localDir.appendingPathComponent("theme.txt")
        guard let t = try? String(contentsOf: oldThemeURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return t
    }
}
