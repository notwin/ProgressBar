<div align="center">

# 进度条 ProgressBar

**轻量级 macOS 原生任务管理应用，专注于项目进度跟踪与跟进记录。**

纯 SwiftUI 构建，无需 Xcode，命令行一键编译部署。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0+-orange.svg)](https://github.com/notwin/ProgressBar)
[![Swift](https://img.shields.io/badge/Swift-6-FA7343.svg)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/notwin/ProgressBar)](https://github.com/notwin/ProgressBar/releases/latest)

<img src="screenshots/main.png" width="700" alt="进度条主界面截图">

</div>

---

## Features

- **多分区管理** — 新建 / 重命名 / 删除分区，按项目组织任务
- **任务状态流转** — 待开始 → 进行中 → 已完成 / 已阻塞，拖拽排序
- **跟进记录** — 为每个任务记录进展日志，输入「阻塞」等关键词自动标记状态
- **日历集成** — 一键同步截止日期到系统日历，修改 / 删除自动同步
- **多格式导出** — 纯文本复制、桌面版 / 手机版 PNG 高清图片
- **7 套主题** — 黑曜石、深渊、砂岩、霓虹、霜冻、纸墨，支持跟随系统
- **iCloud 同步** — 多设备数据自动同步 + 本地自动备份
- **键盘优先** — 全套快捷键，高效操作

## Installation

### 下载安装（推荐）

前往 [Releases](https://github.com/notwin/ProgressBar/releases/latest) 下载最新版 `.zip`，解压后将「进度条.app」拖入 `Applications` 文件夹。

### 从源码编译

```bash
git clone https://github.com/notwin/ProgressBar.git
cd ProgressBar
./build.sh
```

> 脚本自动执行：编译 → 部署到 `/Applications/进度条.app` → ad-hoc 签名 → 启动

**要求**: macOS 14.0+、Swift 6（Xcode Command Line Tools）

## Usage

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘N` | 新建任务 |
| `⌘F` | 搜索任务 |
| `⇧⌘C` | 复制到剪贴板 |
| `⌘E` | 导出图片 |
| `⇧⌘S` | 同步到日历 |
| `⌘/` | 快捷键一览 |

### 主题

| 主题 | 风格 |
|------|------|
| 自动 | 跟随系统深浅色 |
| 黑曜石 | 深蓝黑底 + 靛蓝，灵感 Linear |
| 深渊 | 深海青绿 + 亮青，灵感 Arc |
| 砂岩 | 暖色大地调 + 琥珀 |
| 霓虹 | 赛博朋克暗紫 + 荧光色 |
| 霜冻 | 柔和冷色调，灵感 Nord |
| 纸墨 | 暖白 + 钴蓝，灵感 Things 3 |

### 数据存储

| 路径 | 说明 |
|------|------|
| `~/Library/Mobile Documents/com~apple~CloudDocs/ProgressBar/data.json` | iCloud 同步 |
| `~/Library/Application Support/ProgressBar/data.json` | 本地备份 |

## Project Structure

```
ProgressBar/
├── Models.swift              # 数据模型、状态定义
├── Theme.swift               # 7 套主题配色系统
├── AppState.swift            # 应用状态管理、CRUD、日历同步
├── PersistenceManager.swift  # 数据持久化、iCloud 同步
├── CalendarManager.swift     # 系统日历集成
├── ContentView.swift         # 主视图布局、搜索、快捷键
├── TaskRowView.swift         # 任务行视图、状态切换、日志
├── SectionTabBar.swift       # 分区标签栏
├── ArchiveSectionView.swift  # 归档区域
├── CalendarPicker.swift      # 日历日期选择器
├── ExportCardView.swift      # 导出图片渲染
├── ThemePickerView.swift     # 主题选择面板
├── ProgressBarApp.swift      # 应用入口
├── build.sh                  # 一键编译部署脚本
└── AppBundle/                # App Bundle 模板
```

## Tech Stack

- **Language**: Swift 6
- **UI**: SwiftUI + AppKit
- **Calendar**: EventKit
- **Build**: `swiftc` (no Xcode project needed)
- **Min OS**: macOS 14.0 Sonoma

## Contributing

欢迎贡献！请查看 [Contributing Guide](CONTRIBUTING.md) 了解详情。

## License

[MIT](LICENSE) © notwin
