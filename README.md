# 进度条

一款轻量级 macOS 原生任务管理应用，专注于项目进度跟踪与跟进记录。使用纯 SwiftUI 构建，无需 Xcode，命令行一键编译部署。

![主界面](screenshots/main.png)

## 功能特性

### 任务管理
- 多分区管理，支持新建/重命名/删除分区
- 任务状态流转：待开始 → 进行中 → 已完成 / 已阻塞
- 拖拽排序，截止日期设置（日历选择器）
- 截止日期过期自动红色高亮警告
- 双击编辑任务标题，hover 显示操作按钮
- 完成与归档分离，归档任务可恢复

### 跟进记录
- 为每个任务添加进展日志，自动记录日期
- 默认显示最新 3 条，点击展开全部
- 智能状态推断：输入含「卡点/阻塞」等关键词自动标记为已阻塞
- 导出时输出全量记录

### 日历集成
- 一键将所有有截止日期的任务同步到系统日历
- 创建专属「进度条」紫色日历，不干扰其他日历
- 修改截止日期/删除任务/归档时自动同步
- 日历同步状态图标实时显示

### 导出
- 复制为纯文本（Emoji 状态标识）
- 导出为桌面版/手机版 PNG 高清图片
- 导出内容为全量任务 + 跟进记录（不含归档）

### 主题系统

7 套差异化高品质配色，点击右上角主题按钮切换：

| 主题 | 风格 |
|------|------|
| 自动 | 跟随系统深浅色，自动切换黑曜石/纸墨 |
| 黑曜石 | 深蓝黑底 + 柔和靛蓝，灵感 Linear |
| 深渊 | 深海青绿 + 明亮青色，灵感 Arc |
| 砂岩 | 暖色大地调 + 琥珀，皮革质感 |
| 霓虹 | 赛博朋克暗紫 + 荧光色 |
| 霜冻 | 柔和冷色调，灵感 Nord / Catppuccin |
| 纸墨 | 高级暖白 + 钴蓝，灵感 Things 3 |

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘N` | 新建任务 |
| `⌘F` | 搜索任务 |
| `⇧⌘C` | 复制到剪贴板 |
| `⌘E` | 导出图片 |
| `⇧⌘S` | 同步到日历 |
| `⌘/` | 快捷键一览 |
| `Enter` | 提交输入 |
| `Esc` | 取消 / 退出编辑 |
| `双击标题` | 编辑任务名称 |

### 数据同步
- iCloud Drive 自动同步，多设备数据一致
- 本地自动备份，防止数据丢失

## 技术栈

- **语言**: Swift 6
- **框架**: SwiftUI + AppKit + EventKit
- **编译**: 命令行 `swiftc`，无需 Xcode
- **最低系统**: macOS 14.0
- **Bundle ID**: `com.notwin.progressbar`

## 项目结构

```
ProgressBar/
├── Models.swift            # 数据模型、状态定义、日期工具函数、动画常量
├── Theme.swift             # 7 套主题配色系统
├── AppState.swift          # 应用状态管理、CRUD、日历同步、数据持久化
├── ContentView.swift       # 主视图布局、导出、搜索、快捷键
├── TaskRowView.swift       # 任务行视图、状态切换、日志、编辑
├── SectionTabBar.swift     # 分区标签栏
├── ArchiveSectionView.swift # 归档区域
├── CalendarPicker.swift    # 日历日期选择器
├── ExportCardView.swift    # 导出图片渲染视图
├── ThemePickerView.swift   # 主题选择面板
├── ProgressBarApp.swift    # 应用入口、快捷键命令
├── build.sh                # 一键编译部署脚本
└── AppBundle/
    └── Contents/
        ├── Info.plist      # 应用配置（含日历权限声明）
        └── Resources/
            └── AppIcon.icns
```

## 编译部署

```bash
# 一键编译 + 部署到 /Applications/进度条.app + 签名 + 启动
./build.sh
```

脚本自动执行：编译 → 关闭旧实例 → 部署到 `/Applications/进度条.app` → ad-hoc 签名 → 启动应用

## 数据存储

- **iCloud 可用时**: `~/Library/Mobile Documents/com~apple~CloudDocs/ProgressBar/data.json`
- **本地备份**: `~/Library/Application Support/ProgressBar/data.json`
- 数据格式为 JSON，包含分区、任务、日志、主题设置

## License

MIT
